# incus-mig-script
A script to automate the creation of incus Ubuntu containers using NVIDIA MIG GPUs.

This script requires that you have incus installed and configured as well as the CUDA toolkit and that you have configured at least one MIG device. It uses pwgen to generate passwords.

You will need to adjust the Network Default variables to match your network before running this script.

This script presumes that all of your MIG GPUs have the same configuration hence it just attaches any unused MIG GPU to the container when you use the -g option.

It also auto-assigns an IP address to the container (if non is specified), configures snapshots (one every 12 hours), installs openssh-server and configures a password for the root user.
