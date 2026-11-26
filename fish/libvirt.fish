# ~/.config/fish/conf.d/libvirt.fish
# Make virsh / virt-install / virt-viewer use the system libvirt instance
set -gx LIBVIRT_DEFAULT_URI qemu:///system
