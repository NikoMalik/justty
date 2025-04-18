fast:
	@zig build -Doptimize=ReleaseFast


debug:
	@zig build -Doptimize=Debug



run:
	@./zig-out/bin/justty
