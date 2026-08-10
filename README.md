# tri-plane-infrastructure

Documents, scripts, and other files related to my tri-plane (compute, storage, network) infrastructure stack.

The infrastructure stack consists of 3 3-node clusters. One cluster provides general compute, one provides shared storage, and one provides networking.

```text
tri-plane-infrastructure/
├── LICENSE                 # GPL 2.0 license
├── README.md               # This README
├── docs/                   # Infrastructure documentation
│   ├── architecture.md        # Architecture description
│   ├── build.md               # Infrastructure setup instructions
│   ├── diagram.asc         # Architecture diagram (extended ASCII)
│   └── diagram.txt         # Architecture diagram (plain-text)
└── scripts/                # Infrastructure documentation
    ├── autoinstall-hook.sh # Hook script for Slackware auto-install
    ├── autoinstall.sh      # Automated installation script for Slackware
    ├── build-initrd.sh     # Create custom initrd with autoinstall hook
    ├── build-usb-image.sh  # Create custom Slackware install USB
    ├── imageinstall.sh     # Slackware tarball image installer
    └── sync-mirror.sh      # Slackware mirror sync script
```
