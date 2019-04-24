# {{docker build -t sysboottest:latest .} && {docker run -i --rm sysboottest}}
#
# https://hub.docker.com/r/uroottest/test-image-amd64/dockerfile
FROM uroottest/test-image-amd64:v3.2.4

RUN sudo apt-get update &&                          \
	sudo apt-get install -y --no-install-recommends \
		`# Linux dependencies` \
		git \
		bc \
		bison \
		flex \
		gcc \
		make \
		`# QEMU dependencies` \
		libglib2.0-dev \
		libfdt-dev \
		libpixman-1-dev \
		zlib1g-dev \
		`# Linux kernel build deps` \
		libelf-dev \
		`# Multiboot kernel build deps` \
		gcc-multilib \
		gzip \
		`# coreboot deps` \
		patch \
		`# coreboot optional deps (faster builds)` \
		gcc \
		clang \
		iasl \
		`# vpd deps` \
		uuid-dev \
		xxd \
		`# to be put into u-root` \
		strace \
		`# tools for creating bootable disk images` \
		gdisk \
		e2fsprogs \
		qemu-utils \
		&& \
	sudo rm -rf /var/lib/apt/lists/*

# get vpd
RUN git clone --branch=release-R74-11895.B https://chromium.googlesource.com/chromiumos/platform/vpd
RUN (cd vpd && \
		make && \
		make test && \
		sudo cp vpd /bin/vpd \
	) && \
	rm -rf vpd/ && \
	type vpd

# get configs
RUN git clone https://github.com/linuxboot/demo.git

# get u-root+systemboot
RUN set -x; \
	go get  \
		github.com/u-root/u-root \
		github.com/systemboot/systemboot/uinit \
		github.com/systemboot/systemboot/localboot \
		github.com/systemboot/systemboot/netboot \
		&& \
	u-root \
		-build=bb \
		-files /usr/bin/strace \
		core \
		github.com/systemboot/systemboot/uinit \
		github.com/systemboot/systemboot/localboot \
		github.com/systemboot/systemboot/netboot \
		&& \
	xz --check=crc32 --lzma2=dict=512KiB /tmp/initramfs.linux_amd64.cpio

# get the right linux
RUN set -x; \
	git clone -q --depth 1 -b v4.19 https://github.com/torvalds/linux.git && \
	sed -e '/^# CONFIG_RELOCATABLE / s!.*!CONFIG_RELOCATABLE=y!' `# for kexec` \
		demo/20190203-FOSDEM-barberio-hendricks/config/linux-config \
		> linux/.config && \
	(cd linux/ && exec make -j$(nproc)) && \
	cp linux/arch/x86/boot/bzImage bzImage && \
	rm -r linux/

# get Coreboot
#
RUN set -x; \
	git clone -q --depth 1 https://review.coreboot.org/coreboot.git && \
	cp demo/20190203-FOSDEM-barberio-hendricks/config/qemu.fmd coreboot/qemu.fmd && \
	sed -e '/^CONFIG_FMDFILE=/ s!=.*!="qemu.fmd"!' \
		-e '/^CONFIG_PAYLOAD_FILE=/ s!=.*!="../bzImage"!' \
		-e '/CONFIG_ANY_TOOLCHAIN/ s!.*!CONFIG_ANY_TOOLCHAIN=y!' `# speeds up things` \
        		demo/20190203-FOSDEM-barberio-hendricks/config/coreboot-config \
        		> coreboot/.config && \
	(cd coreboot && \
		git submodule update --init --checkout && \
		: `# cherry-pick VPD-on-Qemu patch, https://review.coreboot.org/c/coreboot/+/32087` && \
		git config user.email "you@example.com" && \
		git config user.name "Your Name" && \
		git fetch https://review.coreboot.org/coreboot refs/changes/87/32087/6 && \
		git cherry-pick FETCH_HEAD && \
		: skip this... BUILD_LANGUAGES=c CPUS=$(nproc) make -j$(nproc) crossgcc-i386 && \
		make -j$(nproc) \
	) && \
	cp coreboot/build/coreboot.rom coreboot.rom && \
	rm -rf coreboot/

# create a bootable linux disk image to test systemboot; the init simply shuts down.
RUN set -x; \
	mkdir rootfs && \
	cp bzImage rootfs/ && \
	u-root -build=bb -o rootfs/ramfs.cpio -initcmd shutdown  && \
	xz --check=crc32 --lzma2=dict=512KiB rootfs/ramfs.cpio && \
	{ \
		echo menuentry; \
		echo linux bzImage; \
		echo initrd ramfs.cpio.xz; \
	} > rootfs/grub2.cfg && \
	du -a rootfs/ && \
	qemu-img create -f raw disk.img 20m && \
	sgdisk --clear \
		--new 1::-0 --typecode=1:8300 --change-name=1:'Linux root filesystem' \
		disk.img && \
	mkfs.ext2 -F -E 'offset=1048576' -d rootfs/ disk.img 18m && \
	gdisk -l disk.img && \
	qemu-img convert -f raw -O qcow2 disk.img disk.qcow2 && \
	mv disk.qcow2 disk.img && \
	rm -r rootfs/

# Write VPD variables. These will be available read-only via /sys/firmware/vpd/*
RUN set -x; \
	: `# RW_VPD partition` && \
	vpd -f coreboot.rom -i RW_VPD -O && \
	vpd -f coreboot.rom -i RW_VPD -s 'LinuxBoot=IsCool' && \
	: `# RO_VPD partition` && \
	vpd -f coreboot.rom -i RO_VPD -O && \
	vpd -f coreboot.rom -i RO_VPD -s 'Boot0000={"type":"localboot","method":"grub"}' && \
	vpd -f coreboot.rom -i RO_VPD -g Boot0000

CMD ./qemu-system-x86_64 \
	-M q35 \
	-L pc-bios/ `# for vga option rom` \
	-bios coreboot.rom \
	-m 1024 \
	-nographic \
	-object 'rng-random,filename=/dev/urandom,id=rng0' \
	-device 'virtio-rng-pci,rng=rng0' \
	-hda disk.img
