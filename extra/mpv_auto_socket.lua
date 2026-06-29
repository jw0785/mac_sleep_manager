local pid = mp.get_property("pid")
mp.set_property("input-ipc-server", "/tmp/mpvsocket." .. pid)
