CAPNP_LIB = interface_capnp.rs

.PHONY: all clean

all: $(CAPNP_LIB)

interface_capnp.rs: interface.capnp
	capnp compile $^ -orust

clean:
	rm -f $(CAPNP_LIB)
