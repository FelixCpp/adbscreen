// Command adbscreen-usbmirror-helper bridges a USB-connected iOS device's
// screen-mirroring video stream (the same private "QuickTime X" USB
// configuration that QuickTime Player and Xcode use — enabled here via the
// vendored, reverse-engineered github.com/danielpaulus/quicktime_video_hack
// library) to ADBScreen over a Unix domain socket.
//
// Wire format matches adbscreen-airplay-helper exactly, so the Swift side
// reuses the same frame parser: 1-byte type tag, 4-byte big-endian length,
// payload.
//   - type 0x00: an Annex-B H.264 video frame (may contain SPS/PPS NALs
//     followed by one or more VCL NALs, exactly as they arrived in a single
//     CMSampleBuffer).
//   - type 0x01: a UTF-8 device name, sent once as soon as it's known.
//
// No audio is forwarded (ADBScreen doesn't play back USB-mirrored audio).
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/danielpaulus/quicktime_video_hack/screencapture"
	"github.com/danielpaulus/quicktime_video_hack/screencapture/coremedia"
	"github.com/google/gousb"
	log "github.com/sirupsen/logrus"
)

const (
	frameTypeVideo      byte = 0x00
	frameTypeDeviceName byte = 0x01
)

func main() {
	udid := flag.String("udid", "", "UDID/serial of the iOS device to mirror; first device found if omitted")
	flag.Parse()

	log.SetLevel(log.WarnLevel) // keep stderr quiet; ADBScreen only surfaces the termination message

	sockPath := os.Getenv("ADBSCREEN_VIDEO_SOCK")
	if sockPath == "" {
		fmt.Fprintln(os.Stderr, "ADBSCREEN_VIDEO_SOCK is not set")
		os.Exit(1)
	}

	conn, err := dialWithRetry(sockPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to connect to %s: %s\n", sockPath, err)
		os.Exit(1)
	}
	defer conn.Close()

	// The vendored gousb/quicktime_video_hack libraries (last updated ~2020)
	// occasionally *panic* instead of returning an error when libusb fails to
	// (re-)initialize a context — this reliably happens because EnableQTConfig
	// itself tears down and recreates a libusb context up to 10 times while
	// waiting for the device to re-enumerate after the USB config switch.
	// Retry the whole attempt a few times with backoff, converting panics
	// into a clean error, rather than letting one flaky libusb hiccup kill
	// the helper process outright.
	const maxAttempts = 5
	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if err := runOnce(*udid, conn); err != nil {
			lastErr = err
			fmt.Fprintf(os.Stderr, "attempt %d/%d failed: %s\n", attempt, maxAttempts, err)
			time.Sleep(time.Duration(attempt) * time.Second)
			continue
		}
		return
	}
	fmt.Fprintf(os.Stderr, "giving up after %d attempts: %s\n", maxAttempts, lastErr)
	os.Exit(1)
}

// runOnce performs one full device-find → activate → stream attempt using a
// single libusb context for its entire duration (see
// adbscreen_shared_context.go), recovering from panics raised by the
// vendored USB libraries and reporting them as a plain error instead.
func runOnce(udid string, conn net.Conn) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("recovered from panic: %v", r)
		}
	}()

	ctx := gousb.NewContext()
	defer ctx.Close()

	device, findErr := waitForDevice(ctx, udid)
	if findErr != nil {
		return findErr
	}

	writer := &socketWriter{conn: conn}
	writer.writeDeviceName(device.ProductName)

	device, enableErr := screencapture.EnableQTConfigWithContext(ctx, device)
	if enableErr != nil {
		return fmt.Errorf("failed to enable screen-mirroring USB config: %w", enableErr)
	}

	adapter := screencapture.UsbAdapter{}
	stopSignal := make(chan interface{})
	mp := screencapture.NewMessageProcessor(&adapter, stopSignal, writer, false)

	if readErr := adapter.StartReading(ctx, device, &mp, stopSignal); readErr != nil {
		return fmt.Errorf("usb streaming stopped: %w", readErr)
	}
	return nil
}

// dialWithRetry connects to the Unix socket ADBScreen is listening on. The
// listener is created before this process is spawned, but give it a moment
// in case of a scheduling race.
func dialWithRetry(path string) (net.Conn, error) {
	var lastErr error
	for i := 0; i < 50; i++ {
		conn, err := net.Dial("unix", path)
		if err == nil {
			return conn, nil
		}
		lastErr = err
		time.Sleep(100 * time.Millisecond)
	}
	return nil, lastErr
}

// waitForDevice polls for a connected, paired iOS device using the shared
// context. USB device discovery via usbmux enumeration can lag a second or
// two behind the physical plug-in event, and we'd rather wait than fail
// immediately.
func waitForDevice(ctx *gousb.Context, udid string) (screencapture.IosDevice, error) {
	deadline := time.Now().Add(30 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		device, err := screencapture.FindIosDeviceWithContext(ctx, udid)
		if err == nil {
			return device, nil
		}
		lastErr = err
		time.Sleep(500 * time.Millisecond)
	}
	return screencapture.IosDevice{}, fmt.Errorf("no iOS device found via USB: %w", lastErr)
}

// socketWriter implements screencapture.CmSampleBufConsumer, forwarding
// video NALs (Annex-B framed, one message per CMSampleBuffer) to ADBScreen.
// Modeled on coremedia.AVFileWriter, but framing each buffer as a socket
// message instead of appending to a file.
type socketWriter struct {
	conn net.Conn
	buf  []byte
}

var annexBStartCode = []byte{0x00, 0x00, 0x00, 0x01}

func (w *socketWriter) Consume(buf coremedia.CMSampleBuffer) error {
	if buf.MediaType == coremedia.MediaTypeSound {
		return nil // audio isn't forwarded
	}
	w.buf = w.buf[:0]
	if buf.HasFormatDescription {
		w.appendNalu(buf.FormatDescription.PPS)
		w.appendNalu(buf.FormatDescription.SPS)
	}
	if buf.HasSampleData() {
		w.appendNalus(buf.SampleData)
	}
	if len(w.buf) == 0 {
		return nil
	}
	return w.writeFrame(frameTypeVideo, w.buf)
}

func (w *socketWriter) Stop() {}

func (w *socketWriter) appendNalus(data []byte) {
	for len(data) > 0 {
		length := binary.BigEndian.Uint32(data)
		end := 4 + length
		w.appendNalu(data[4:end])
		data = data[end:]
	}
}

func (w *socketWriter) appendNalu(nalu []byte) {
	w.buf = append(w.buf, annexBStartCode...)
	w.buf = append(w.buf, nalu...)
}

func (w *socketWriter) writeDeviceName(name string) {
	_ = w.writeFrame(frameTypeDeviceName, []byte(name))
}

func (w *socketWriter) writeFrame(typeTag byte, payload []byte) error {
	header := make([]byte, 5)
	header[0] = typeTag
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	if _, err := w.conn.Write(header); err != nil {
		return err
	}
	_, err := w.conn.Write(payload)
	return err
}
