SHELL = /bin/sh

.PHONY: all
all: ubuntu-image

.PHONY: toolchain
toolchain: buildroot/output/host/bin/aarch64-linux-gcc
buildroot/output/host/bin/aarch64-linux-gcc:
	$(MAKE) -C buildroot imx8mm_venice_defconfig
	$(MAKE) -C buildroot toolchain

.PHONY: buildroot
buildroot:
	$(MAKE) -C buildroot imx8mm_venice_defconfig all

# ATF
ATF_ARGS += PLAT=imx8mm
atf: u-boot/bl31.bin
u-boot/bl31.bin: toolchain
	$(MAKE) -C atf $(ATF_ARGS) bl31
	ln -sf ../atf/build/imx8mm/release/bl31.bin u-boot/

# ddr-firmware
DDR_FIRMWARE_URL:=https://www.nxp.com/lgfiles/NMG/MAD/YOCTO
DDR_FIRMWARE_VER:=firmware-imx-8.0
DDR_FIRMWARE_FILES := \
	lpddr4_pmu_train_1d_dmem.bin \
	lpddr4_pmu_train_1d_imem.bin \
	lpddr4_pmu_train_2d_dmem.bin \
	lpddr4_pmu_train_2d_imem.bin
ddr-firmware: $(DDR_FIRMWARE_VER)/firmware/ddr/synopsys
$(DDR_FIRMWARE_VER)/firmware/ddr/synopsys:
	wget -N $(DDR_FIRMWARE_URL)/$(DDR_FIRMWARE_VER).bin
	$(SHELL) $(DDR_FIRMWARE_VER).bin --auto-accept
	for file in $(DDR_FIRMWARE_FILES); do ln -s ../$@/$${file} u-boot/; done

# uboot
uboot: u-boot/flash.bin
u-boot/flash.bin: toolchain atf ddr-firmware
	$(MAKE) -C u-boot imx8mm_venice_defconfig
	$(MAKE) -C u-boot flash.bin

# kernel
linux: linux/arch/arm64/boot/Image
linux/arch/arm64/boot/Image: toolchain
	$(MAKE) -C linux imx8mm_venice_defconfig
	$(MAKE) -C linux Image modules

.PHONY: kernel_image
kernel_image: linux linux-venice.tar.xz
linux-venice.tar.xz:
	# install dir
	rm -rf linux/install
	mkdir -p linux/install/boot
	cp linux/arch/arm64/boot/Image linux/install/boot
	make -C linux INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=install modules_install
	make -C linux INSTALL_HDR_PATH=install/usr headers_install
	# cryptodev-linux build/install
	make -C cryptodev-linux KERNEL_DIR=../linux
	make -C cryptodev-linux KERNEL_DIR=../linux DESTDIR=../linux/install INSTALL_MOD_PATH=../linux/install install
	# tarball
	tar -cvJf linux-venice.tar.xz --numeric-owner -C linux/install .

# ubuntu
UBUNTU_FSSZMB ?= 1536
UBUNTU_REL ?= focal
UBUNTU_FS ?= $(UBUNTU_REL)-venice.ext4
UBUNTU_IMG ?= $(UBUNTU_REL)-venice.img
$(UBUNTU_REL)-venice.tar.xz:
	wget -N http://dev.gateworks.com/ubuntu/$(UBUNTU_REL)/$(UBUNTU_REL)-venice.tar.xz

.PHONY: ubuntu-image
ubuntu-image: uboot kernel_image $(UBUNTU_REL)-venice.tar.xz
	$(eval TMP := $(shell mktemp -d))
	mkdir -p $(TMP)/boot
	# create kernel.itb with compressed kernel image
	cp linux/arch/arm64/boot/Image vmlinux
	gzip -f vmlinux
	u-boot/tools/mkimage -f auto -A $(ARCH) \
		-O linux -T kernel -C gzip \
		-a $(LOADADDR) -e $(LOADADDR) -n "Ubuntu $(UBUNTU_REL)" \
		-d vmlinux.gz $(TMP)/boot/kernel.itb
	# create U-Boot bootscript
	u-boot/tools/mkimage -A $(ARCH) -T script -C none \
		-d venice/boot.scr $(TMP)/boot/boot.scr
	# root filesystem
	sudo ./venice/mkfs ext4 $(UBUNTU_FS) $(UBUNTU_FSSZMB)M \
		$(UBUNTU_REL)-venice.tar.xz linux-venice.tar.xz $(TMP)
	rm -rf $(TMP)
	# disk image
	truncate -s $$(($(UBUNTU_FSSZMB) + 16))M $(UBUNTU_IMG)
	dd if=u-boot/flash.bin of=$(UBUNTU_IMG) bs=1k seek=33 oflag=sync
	dd if=$(UBUNTU_FS) of=$(UBUNTU_IMG) bs=1M seek=16
	# partition table
	printf "$$((16*2*1024)),,L,*" | sfdisk -uS $(UBUNTU_IMG)
	# compress
	gzip -f $(UBUNTU_IMG)

.PHONY: clean
clean:
	make -C buildroot clean
	make -C u-boot clean
	make -C atf $(ATF_ARGS) clean
	make -C linux clean
	rm -rf linux/install
	rm -rf $(DDR_FIRMWARE_VER)

.PHONY: distclean
distclean:
	make -C buildroot distclean
	make -C u-boot distclean
	make -C atf $(ATF_ARGS) distclean
	make -C linux distclean
	rm -rf linux/install
	rm -rf $(DDR_FIRMWARE_VER)
