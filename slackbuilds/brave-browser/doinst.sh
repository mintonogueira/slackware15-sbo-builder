if [ -x usr/bin/update-desktop-database ]; then
  chroot . /usr/bin/update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || true
fi

if [ -x usr/bin/gtk-update-icon-cache ]; then
  for icon_theme in usr/share/icons/*; do
    [ -d "$icon_theme" ] || continue
    chroot . /usr/bin/gtk-update-icon-cache -q -t "/$icon_theme" >/dev/null 2>&1 || true
  done
fi
