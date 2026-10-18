apexd and com.android.tethering.capex taken from Kyros70/PixelOS_treble release 20261010
(PixelOS 17.0 GSI built with gsi-patches).
netd is NOT replaced: HyperOS netd carries Xiaomi OemNetd (MIUI firewall, traffic limiter) that
miui-services depends on, the AOSP netd does not have it.
