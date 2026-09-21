package screencapture

// ADBScreen-specific additions on top of the vendored quicktime_video_hack
// library.
//
// discovery.go's FindIosDevice and activator.go's EnableQTConfig each open
// their own gousb.Context (and EnableQTConfig closes/reopens it up to 10
// times in a polling loop while waiting for the device to re-enumerate
// after the USB config switch). Calling these repeatedly from a long-running
// process — as our helper's own device-presence poll loop does on top of
// that — creates and tears down many libusb/IOKit master port connections
// in quick succession within the same process. On macOS this reliably
// triggers sporadic "libusb: unknown error [code -99]" failures from
// gousb.NewContext() (a known IOKit master-port churn issue, not something
// fixable from outside the library). The fix is to open exactly one
// gousb.Context for the helper's entire lifetime and thread it through
// instead of letting the library create fresh ones.

import (
	"fmt"
	"time"

	"github.com/google/gousb"
	log "github.com/sirupsen/logrus"
)

// FindIosDeviceWithContext is discovery.FindIosDevice, but reusing a
// caller-supplied context instead of creating (and leaking) a new one.
func FindIosDeviceWithContext(ctx *gousb.Context, usbSerial string) (IosDevice, error) {
	list, err := findIosDevices(ctx, isValidIosDevice)
	if err != nil {
		return IosDevice{}, err
	}
	if len(list) == 0 {
		return IosDevice{}, fmt.Errorf("no iOS devices are connected to this host")
	}
	if usbSerial == "" {
		return list[0], nil
	}
	for _, device := range list {
		if usbSerial == device.SerialNumber {
			return device, nil
		}
	}
	return IosDevice{}, fmt.Errorf("device with usbSerial:'%s' not found", usbSerial)
}

// EnableQTConfigWithContext is activator.EnableQTConfig, but reusing a
// caller-supplied context (never closing it) instead of closing/reopening a
// context on every poll iteration.
func EnableQTConfigWithContext(ctx *gousb.Context, device IosDevice) (IosDevice, error) {
	usbSerial := device.SerialNumber
	usbDevice, err := OpenDevice(ctx, device)
	if err != nil {
		return IosDevice{}, err
	}
	if isValidIosDeviceWithActiveQTConfig(usbDevice.Desc) {
		log.Debugf("Skipping %s because it already has an active QT config", usbSerial)
		usbDevice.Close()
		return device, nil
	}

	sendQTConfigControlRequest(usbDevice)
	usbDevice.Close()

	for i := 0; i < 20; i++ {
		time.Sleep(500 * time.Millisecond)
		reopened, err := OpenDevice(ctx, device)
		if err != nil {
			log.Debugf("device not found while waiting for QT config: %s", err)
			continue
		}
		activated := isValidIosDeviceWithActiveQTConfig(reopened.Desc)
		mux, qt := findConfigurations(reopened.Desc)
		reopened.Close()
		if activated {
			device.UsbMuxConfigIndex = mux
			device.QTConfigIndex = qt
			return device, nil
		}
	}
	return IosDevice{}, fmt.Errorf("could not activate Quicktime Config for %s", usbSerial)
}
