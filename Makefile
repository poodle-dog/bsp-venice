SHELL = /bin/sh

.PHONY: all
all: ubuntu-image

# Toolchain
.PHONY: toolchain
toolchain: buildroot/output/host/bin/aarch64-linux-gcc
buildroot/output/host/bin/aarch64-linux-gcc:
	$(MAKE) -C buildroot imx8mm_venice_defconfig
	$(MAKE) -C buildroot toolchain

# Buildroot
.PHONY: buildroot
buildroot:
	$(MAKE) -C buildroot imx8mm_venice_defconfig all

# ddr-firmware
DDR_FIRMWARE_URL:=https://www.nxp.com/lgfiles/NMG/MAD/YOCTO
DDR_FIRMWARE_VER:=firmware-imx-8.10
DDR_FIRMWARE_FILES := \
	lpddr4_pmu_train_1d_dmem.bin \
	lpddr4_pmu_train_1d_imem.bin \
	lpddr4_pmu_train_2d_dmem.bin \
	lpddr4_pmu_train_2d_imem.bin \
	lpddr4_pmu_train_1d_dmem_202006.bin \
	lpddr4_pmu_train_1d_imem_202006.bin \
	lpddr4_pmu_train_2d_dmem_202006.bin \
	lpddr4_pmu_train_2d_imem_202006.bin
ddr-firmware: $(DDR_FIRMWARE_VER)/firmware/ddr/synopsys
$(DDR_FIRMWARE_VER)/firmware/ddr/synopsys:
	wget -N $(DDR_FIRMWARE_URL)/$(DDR_FIRMWARE_VER).bin
	$(SHELL) $(DDR_FIRMWARE_VER).bin --auto-accept

# Gateworks tool for creating binaries for jtag_usbv4
mkimage_jtag:
	wget -N http://dev.gateworks.com/jtag/mkimage_jtag
	chmod +x mkimage_jtag

# uboot
.NOTPARALLEL: venice-imx8mm-flash.bin imx8mn-flash.bin imx8mp-flash.bin uboot-envtools
.PHONY: uboot
uboot: venice-imx8mm-flash.bin venice-imx8mn-flash.bin venice-imx8mp-flash.bin
venice-imx8mm-flash.bin: toolchain atf ddr-firmware mkimage_jtag
	for file in $(DDR_FIRMWARE_FILES); do \
		cp $(DDR_FIRMWARE_VER)/firmware/ddr/synopsys/$${file} u-boot/; \
	done
	$(MAKE) -C atf PLAT=imx8mm bl31
	ln -sf ../atf/build/imx8mm/release/bl31.bin u-boot/
	$(MAKE) -C u-boot imx8mm_venice_defconfig
	$(MAKE) -C u-boot flash.bin
	cp u-boot/flash.bin venice-imx8mm-flash.bin

venice-imx8mn-flash.bin: toolchain atf ddr-firmware mkimage_jtag
	for file in $(DDR_FIRMWARE_FILES); do \
		cp $(DDR_FIRMWARE_VER)/firmware/ddr/synopsys/$${file} u-boot/; \
	done
	$(MAKE) -C atf PLAT=imx8mn bl31
	ln -sf ../atf/build/imx8mn/release/bl31.bin u-boot/
	$(MAKE) -C u-boot imx8mn_venice_defconfig
	$(MAKE) -C u-boot flash.bin
	cp u-boot/flash.bin venice-imx8mn-flash.bin

venice-imx8mp-flash.bin: toolchain atf ddr-firmware mkimage_jtag
	for file in $(DDR_FIRMWARE_FILES); do \
		cp $(DDR_FIRMWARE_VER)/firmware/ddr/synopsys/$${file} u-boot/; \
	done
	$(MAKE) -C atf PLAT=imx8mp bl31
	ln -sf ../atf/build/imx8mp/release/bl31.bin u-boot/
	$(MAKE) -C u-boot imx8mp_venice_defconfig
	$(MAKE) -C u-boot flash.bin
	cp u-boot/flash.bin venice-imx8mp-flash.bin

.PHONY: uboot-envtools
uboot-envtools: u-boot/tools/env/fw_setenv
u-boot/tools/env/fw_setenv:
	$(MAKE) CROSS_COMPILE= -C u-boot imx8mm_venice_defconfig envtools
	ln -sf fw_printenv u-boot/tools/env/fw_setenv

# JTAG images of boot firmware only and boot firmware + environment
.PHONY: firmware-image
firmware-image: venice-imx8mm-flash.bin venice-imx8mn-flash.bin venice-imx8mp-flash.bin uboot-envtools
	# start with uboot env at end of 4MiB (per venice/fw_env.config)
	truncate -s 4M firmware.img
	u-boot/tools/env/fw_setenv --lock venice/. --config venice/fw_env.config --script venice/venice.env
	# keep copy of env as uboot-env.bin to use later
	dd if=firmware.img of=uboot-env.bin bs=1k skip=4032 count=64 oflag=sync
	# copy backup of uboot env right underneath default env (to allow easy restore of env)
	dd if=uboot-env.bin of=firmware.img bs=1k seek=3968 oflag=sync conv=notrunc
	# copy boot firmware to SOC specific offset for eMMC boot0 partition
	cp firmware.img firmware-venice-imx8mm.img
	dd if=venice-imx8mm-flash.bin of=firmware-venice-imx8mm.img bs=1k seek=33 oflag=sync conv=notrunc
	cp firmware.img firmware-venice-imx8mn.img
	dd if=venice-imx8mn-flash.bin of=firmware-venice-imx8mn.img bs=1k seek=0 oflag=sync conv=notrunc
	cp firmware.img firmware-venice-imx8mp.img
	dd if=venice-imx8mp-flash.bin of=firmware-venice-imx8mp.img bs=1k seek=0 oflag=sync conv=notrunc
	# create boot-firmware JTAG image (bootloader + env) for boot0
	./mkimage_jtag --soc imx8mm --emmc -s --partconf=boot0 \
		firmware-venice-imx8mm.img@boot0:erase_part:0-8192 \
		> firmware-venice-imx8mm.bin
	./mkimage_jtag --soc imx8mn --emmc -s --partconf=boot0 \
		firmware-venice-imx8mn.img@boot0:erase_part:0-8192 \
		> firmware-venice-imx8mn.bin
	./mkimage_jtag --soc imx8mp --emmc -s --partconf=boot0 \
		firmware-venice-imx8mp.img@boot0:erase_part:0-8192 \
		> firmware-venice-imx8mp.bin
	# cleanup
	rm firmware.img

# kernel
KVER = $(shell cd linux; $(MAKE) kernelversion)
.PHONY: linux
linux: linux/arch/arm64/boot/Image
linux/arch/arm64/boot/Image: toolchain
	[ -r linux/arch/arm64/configs/imx8m_venice_defconfig ] || { \
		ln -s imx8mm_venice_defconfig linux/arch/arm64/configs/imx8m_venice_defconfig; \
	}
	$(MAKE) -C linux imx8m_venice_defconfig
ifeq ($(shell expr ${KVER} == "5.15.15"),1)
	$(MAKE) DTC_FLAGS="-@" -C linux Image dtbs modules
else
	$(MAKE) -C linux Image dtbs modules
endif
.PHONY: kernel_image
kernel_image: linux-venice.tar.xz
linux-venice.tar.xz: linux/arch/arm64/boot/Image venice-imx8mm-flash.bin
	# install dir
	rm -rf build/linux
	mkdir -p build/linux/boot
	# install uncompressed kernel
	cp linux/arch/arm64/boot/Image build/linux/boot
	# install a compressed kernel in a kernel.itb
	gzip -fk linux/arch/arm64/boot/Image
	u-boot/tools/mkimage -f auto -A $(ARCH) \
		-O linux -T kernel -C gzip \
		-a $(LOADADDR) -e $(LOADADDR) -n "Kernel" \
		-d linux/arch/arm64/boot/Image.gz build/linux/boot/kernel.itb
	# install dtbs
	cp linux/arch/arm64/boot/dts/freescale/imx8*-venice-*.dtb* build/linux/boot
	# install kernel modules
	make -C linux INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=../build/linux modules_install
	find build/linux/lib/modules/ -name build -exec rm {} \; # remove the bogus symlink
	# install user space linux headers
	make -C linux INSTALL_HDR_PATH=../build/linux/usr headers_install
	# cryptodev-linux build/install
	make -C cryptodev-linux KERNEL_DIR=../linux
	make -C cryptodev-linux KERNEL_DIR=../linux DESTDIR=../build/linux \
		INSTALL_MOD_PATH=../build/linux install
	# newracom nrc7292 802.11ah driver
	make -C nrc7292/package/src/nrc/ KDIR=$(PWD)/linux modules
	make -C nrc7292/package/src/nrc/ KDIR=$(PWD)/linux \
		INSTALL_MOD_PATH=$(PWD)/build/linux modules_install
	# newracom nrc7292 firmware
	mkdir -p build/linux/lib/firmware
	cp nrc7292/package/evk/sw_pkg/nrc_pkg/sw/firmware/nrc7292_* \
		build/linux/lib/firmware/
	# newracom nrc7292 cli app
	make CC=$(CROSS_COMPILE)gcc LFLAGS=-static -C nrc7292/package/src/cli_app/
	mkdir -p build/linux/usr/local/bin/
	cp nrc7292/package/src/cli_app/cli_app \
		build/linux/usr/local/bin/
	# newracom nrc7292 module params
	mkdir -p build/linux/etc/modprobe.d
	echo "options nrc fw_name=nrc7292_cspi.bin bd_name=nrc7292_bd.dat spi_polling_interval=5" \
		> build/linux/etc/modprobe.d/nrc.conf
	# FTDI USB-SPI driver
	make -C ftdi-usb-spi \
		KDIR=$(PWD)/linux INSTALL_MOD_PATH=$(PWD)/build/linux \
		INSTALL_MOD_STRIP=1 \
		modules modules_install
	# install kernel headers needed for building external modules ( aka linux-devel )
	./venice/configure_kernel_headers.sh $(PWD)/linux $(PWD)/build/linux
	# tarball
	tar -cvJf linux-venice.tar.xz --numeric-owner --owner=0 --group=0 \
		-C build/linux .

# ubuntu
PART_OFFSETMB ?= 16
UBUNTU_FSSZMB ?= 2560
UBUNTU_REL ?= jammy
UBUNTU_FS ?= $(UBUNTU_REL)-venice.ext4
UBUNTU_IMG ?= $(UBUNTU_REL)-venice.img
$(UBUNTU_REL)-venice.tar.xz:
	wget -N http://dev.gateworks.com/ubuntu/$(UBUNTU_REL)/$(UBUNTU_REL)-venice.tar.xz
$(UBUNTU_FS): linux-venice.tar.xz $(UBUNTU_REL)-venice.tar.xz
	# root filesystem
	sudo ./venice/mkfs ext4 $(UBUNTU_FS) $(UBUNTU_FSSZMB)M \
		$(UBUNTU_REL)-venice.tar.xz linux-venice.tar.xz || exit 1
.PHONY: ubuntu-image
ubuntu-image: linux/arch/arm64/boot/Image $(UBUNTU_FS) mkimage_jtag firmware-image
	# create U-Boot bootscript
	$(eval TMP=$(shell mktemp -d -t tmp.XXXXXX))
	sudo mount $(UBUNTU_FS) $(TMP) || exit 1
	sudo u-boot/tools/mkimage -A $(ARCH) -T script -C none \
		-d venice/boot.scr $(TMP)/boot/boot.scr
	sudo umount $(TMP) || exit 1
	rmdir $(TMP)
	# disk image
	truncate -s $$(($(UBUNTU_FSSZMB) + $(PART_OFFSETMB)))M $(UBUNTU_IMG)
	dd if=$(UBUNTU_FS) of=$(UBUNTU_IMG) bs=1M seek=$(PART_OFFSETMB)
	# partition table
	printf "$$(($(PART_OFFSETMB)*2*1024)),,L,*" | sfdisk -uS $(UBUNTU_IMG)
	# copy imx8mm boot firmware so that running 'update_all' script in
	# uboot for imx8mm users that have boot firmware on emmc user partition
	# do not brick their board
	dd if=venice-imx8mm-flash.bin of=$(UBUNTU_IMG) bs=1k seek=33 oflag=sync conv=notrunc
	# copy uboot env to where U-Boot expects it (top of 4MiB)
	dd if=uboot-env.bin of=$(UBUNTU_IMG) bs=1k seek=4032 oflag=sync conv=notrunc
	# copy backup of uboot env right underneath it (to allow easy restore of env)
	dd if=uboot-env.bin of=$(UBUNTU_IMG) bs=1k seek=3968 oflag=sync conv=notrunc
	# compress
	gzip -f $(UBUNTU_IMG)

.PHONY: clean
clean:
	make -C u-boot clean
	make -C atf PLAT=imx8mm clean
	make -C atf PLAT=imx8mn clean
	make -C atf PLAT=imx8mp clean
	make -C linux clean
	make -C cryptodev-linux KERNEL_DIR=../linux clean
	make -C buildroot clean
	rm -f venice-*-flash.bin
	rm -f firmware-venice-*.bin
	rm -rf build
	rm -rf $(DDR_FIRMWARE_VER)*
	rm -rf u-boot/lpddr4_pmu_*.bin
	rm -rf linux-venice.tar.xz
	rm -rf focal-venice.ext4 focal-venice.img.gz focal-venice.tar.xz

.PHONY: distclean
distclean:
	make -C u-boot distclean
	make -C atf PLAT=imx8mm distclean
	make -C atf PLAT=imx8mn distclean
	make -C atf PLAT=imx8mp distclean
	make -C linux distclean
	make -C buildroot distclean
	rm -f venice-*-flash.bin
	rm -f firmware-venice-*.bin
	rm -rf build
	rm -rf $(DDR_FIRMWARE_VER)
