# Compile Linux Kernel for Google Pixel Phone

A step by step guide to compile customized Linux Kernel for your Google Pixel phone.

## Background

Google Pixel and Pixel XL are the first smartphones under Pixel branding released in 2016.

You can backup **unlimited original quality photos** to [Google Photo](https://photo.google.com) via this phone. There are lots of [discussions](https://www.reddit.com/r/googlephotos/comments/1g1ryxb/free_unlimited_google_photos_storage_with_an_og/) and various [tools](https://github.com/master-hax/pixel-backup-gang) available on the internet.

This repo tries to enable NFS and Samba protocol in Linux Kernel, so that you can use network storage rather than purchasing another external flash drive is needed.

## Get a Google Pixel

Before you purchase, always ask if the seller can offer you Bootloader unlockable phone. You can find the phones on eBay or Taobao.

![taobao-seller](imgs/seller.png)

Of course, these are all refurbished phones. This 10 years old phone may not work in current cellular network, so you cannot use it as a daily phone. In our use case, it will stay home and connected via Wi-Fi network to work.

## Check Your Google Pixel Phone

Google Pixel Phone --> Settings --> About phone --> Build number (Click 7 times will enable the Developer options).
![](imgs/pixel-build-number.png)

Google Pixel Phone --Settings --> System --> Advanced --> Developer options --> OEM unlocking

![](imgs/pixel-phone-oem-unlocking-option.png)

- If OEM unlocking option is greyed out and you cannot enable it.
  This device is bootloader locked Pixel phone, copy files to the phone is the only option. But the flash storage will wear and fail depending how much you copy the files.
- If OEM unlocking option can be enabled, congratulations.

## Getting Started

### 1. Compile

Ubuntu 20.04

```shell
# Install dependenecies
sudo apt-get install liblz4-tool python-is-python3 libncurses-dev

# Clone the legacy linux kernel source
# The last OS version of Pixel is 
git clone https://android.googlesource.com/kernel/msm
cd msm
git checkout 72a7a64494e

git clone -b android-10.0.0_r17 https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9
git clone -b android-10.0.0_r17 https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9

sudo cp -r tool-chain/arm-linux-androideabi-4.9 /opt
sudo cp -r tool-chain/aarch64-linux-android-4.9 /opt

export PATH=$PATH:/opt/arm-linux-androideabi-4.9/bin:/opt/aarch64-linux-android-4.9/bin

export ARCH="arm64"
export CROSS_COMPILE="aarch64-linux-android-"
export CROSS_COMPILE_ARM32="arm-linux-androideabi-"

make clean
make mrproper

make marlin_defconfig

// make menuconfig

make -j8
```

### 2. Customize

![](imgs/linux-kernel-menuconfig-enable-nfs-cifs.png)

### 3. Test

### 4. Package

## References

- [pixel1-android10内核编译](https://reao.io/330)
- [[Day-03] AOSP Kernel 下載及編譯](https://ithelp.ithome.com.tw/m/articles/10216998)
- [Android 内核源码编译记录](https://blog.csdn.net/Denny_Chen_/article/details/120806685)
- [pixel backup gang](https://github.com/master-hax/pixel-backup-gang)
- [Free Unlimited Google Photos Storage with an OG Pixel: A Detailed Setup](https://www.reddit.com/r/googlephotos/comments/1g1ryxb/free_unlimited_google_photos_storage_with_an_og/)
