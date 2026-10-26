# Read-only probe: list DepthAI devices + bootloader info. Does not flash anything.
import depthai as dai
print("depthai", dai.__version__)
for d in dai.Device.getAllAvailableDevices():
    print(d.getMxId(), d.name, d.state, d.protocol, d.platform)
    if d.state in (dai.XLinkDeviceState.X_LINK_BOOTLOADER, dai.XLinkDeviceState.X_LINK_FLASH_BOOTED, dai.XLinkDeviceState.X_LINK_UNBOOTED):
        print("  embedded bootloader:", dai.DeviceBootloader.getEmbeddedBootloaderVersion())
