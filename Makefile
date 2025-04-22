fast:
	@zig build -Doptimize=ReleaseFast


debug:
	@zig build -Doptimize=Debug

clean:
	@rm -rf .zig-cache/



prof: clean debug run
	


run:
	@./zig-out/bin/justty
