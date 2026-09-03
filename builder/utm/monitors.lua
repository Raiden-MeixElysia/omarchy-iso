-- UTM scales the guest's 1280x800 display to the device, so Hyprland and GTK draw at scale 1.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.env("GDK_SCALE", "1")
