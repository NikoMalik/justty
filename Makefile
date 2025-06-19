fast:
	@zig build -Doptimize=ReleaseFast 

test:
	@zig build test

prepare:
	@chmod +x setup_cgroups.sh
	@sudo ./setup_cgroups.sh

try: fast
	@./zig-out/bin/justty
	

debug:
	@zig build -Doptimize=Debug 


clean:
	@rm -rf .zig-cache/



prof: clean debug run
	


run:
	@./zig-out/bin/justty
