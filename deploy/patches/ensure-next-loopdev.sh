ensure_next_loopdev() {
	local loopdev loopmaj
	# Suppress stderr: in Podman, losetup -f prints "(lost)" warnings that
	# corrupt the device path if captured.
	loopdev="$(losetup -f 2>/dev/null)" || true
	if [ -z "$loopdev" ]; then
		# losetup -f failed; pre-create missing /dev/loopN nodes
		for i in $(seq 0 15); do
			[ -b "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
		done
		loopdev="$(losetup -f 2>/dev/null)"
	fi
	loopmaj="$(echo "$loopdev" | sed -E 's/.*[^0-9]*?([0-9]+)$/\1/')"
	[[ -b "$loopdev" ]] || mknod "$loopdev" b 7 "$loopmaj"
}
