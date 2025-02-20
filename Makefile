FW_URL		:= https://raw.githubusercontent.com/raspberrypi/firmware/master/boot

SHELL	= /bin/bash
EFI_IPXE_DRIVER := FALSE
EFI_BUILD	:= RELEASE
EFI_ARCH	:= AARCH64
EFI_TOOLCHAIN	:= GCC5
EFI_TIMEOUT	:= 0
EFI_FLAGS	:= --pcd=PcdPlatformBootTimeOut=$(EFI_TIMEOUT) --pcd=PcdRamLimitTo3GB=0 --pcd=PcdRamMoreThan3GB=1 --pcd=PcdSystemTableMode=2 -D IPXE_DRIVER_ENABLE=$(EFI_IPXE_DRIVER)
EFI_SRC		:= edk2-platforms
EFI_DSC		:= $(EFI_SRC)/Platform/RaspberryPi/RPi4/RPi4.dsc
EFI_FDF		:= $(EFI_SRC)/Platform/RaspberryPi/RPi4/RPi4.fdf
EFI_FD		:= Build/RPi4/$(EFI_BUILD)_$(EFI_TOOLCHAIN)/FV/RPI_EFI.fd

IPXE_CROSS	:= aarch64-linux-gnu-
IPXE_SRC	:= ipxe/src
ifeq '$(EFI_IPXE_DRIVER)' 'TRUE'
IPXE_TGT	:= bin-arm64-efi/ipxe.efidrv
else
IPXE_TGT	:= bin-arm64-efi/snp.efi
endif
IPXE_EFI	:= $(IPXE_SRC)/$(IPXE_TGT)
IPXE_CONSOLE    := $(IPXE_SRC)/config/local/rpi/console.h
IPXE_GENERAL    := $(IPXE_SRC)/config/local/rpi/general.h

SDCARD_MB	:= 8
export MTOOLSRC	:= mtoolsrc

DOCKER_DIR	:= docker-tftp-pxe-http

all : tftpboot.zip boot.img

submodules :
	which git && git submodule update --init --recursive && ./apply_patches.sh || true

firmware : firmware/start4.elf firmware/fixup4.dat firmware/bcm2711-rpi-4-b.dtb firmware/overlays/overlay_map.dtb

firmware/%:
	[ -d $(shell dirname $@) ] || mkdir -p $(shell dirname $@)
	wget -O $@ $(FW_URL)/$*

efi : $(EFI_FD)

efi-basetools : submodules
	$(MAKE) -C edk2/BaseTools

$(EFI_FD) : submodules efi-basetools $(IPXE_EFI)
	. ./edksetup.sh && \
	build -b $(EFI_BUILD) -a $(EFI_ARCH) -t $(EFI_TOOLCHAIN) \
		-p $(EFI_DSC) $(EFI_FLAGS)

$(IPXE_GENERAL) : submodules
	mkdir -p $$(dirname $@) || true
	echo "#define	DOWNLOAD_PROTO_HTTPS" > $@
	echo "#define	NTP_CMD" >> $@

$(IPXE_CONSOLE) : submodules
	mkdir -p $$(dirname $@) || true
	echo "#undef	LOG_LEVEL" > $@
	echo "#define	LOG_LEVEL LOG_ALL" >> $@
	echo "#define	CONSOLE_SYSLOG CONSOLE_USAGE_ALL" >> $@

ipxe : $(IPXE_EFI)

$(IPXE_EFI) : submodules $(IPXE_CONSOLE) $(IPXE_GENERAL)
	$(MAKE) -C $(IPXE_SRC) CROSS=$(IPXE_CROSS) CONFIG=rpi $(IPXE_TGT)
ifeq '$(EFI_IPXE_DRIVER)' 'TRUE'
	cp $(IPXE_SRC)/$(IPXE_TGT) $(EFI_SRC)/Drivers/Ipxe/Ipxe.efi
endif

pxe : firmware efi ipxe
	$(RM) -rf pxe
	mkdir -p pxe
	cp -r $(sort $(filter-out firmware/kernel%,$(wildcard firmware/*))) \
		pxe/
	cp config.txt $(EFI_FD) edk2/License.txt pxe/
ifneq '$(EFI_IPXE_DRIVER)' 'TRUE'
	mkdir -p pxe/efi/boot
	cp $(IPXE_SRC)/$(IPXE_TGT) pxe/efi/boot/bootaa64.efi
	cp ./autoexec.ipxe pxe/efi/boot/autoexec.ipxe
endif
	cp ipxe/COPYING* pxe/

tftpboot.zip : pxe
	$(RM) -r $(DOCKER_DIR)/*
	- mkdir $(DOCKER_DIR)/
	cp -r $</efi $(DOCKER_DIR)/efi
	cp ./example/dnsmasq.conf $(DOCKER_DIR)
	cp ./example/docker-compose.yml $(DOCKER_DIR)

	$(RM) -f $@
	#( pushd $< ; zip -q -r ../$@ efi/*  ; popd )
	zip -q -r $@ $(DOCKER_DIR)

boot.img: pxe
	truncate -s $(SDCARD_MB)M $@
	mpartition -I -c -b 32 -s 32 -h 64 -t $(SDCARD_MB) -a "z:"
	mformat -v "pipxe" "z:"
	mcopy -s $(sort $(filter-out pxe/efi%,$(wildcard pxe/*))) "z:"

update:
	git submodule foreach git pull origin master

tag :
	git tag v`git show -s --format='%ad' --date=short | tr -d -`-rpi4

.PHONY : submodules firmware efi efi-basetools $(EFI_FD) ipxe $(IPXE_EFI) pxe

clean :
	$(RM) -rf firmware Build pxe tftpboot.zip boot.img
	if [ -d $(IPXE_SRC) ] ; then $(MAKE) -C $(IPXE_SRC) clean ; fi
