const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const gc = @import("gc");

// ALLOCATOR IMPLEMENTATION

pub fn allocator() Allocator {
    if (gc.GC_is_init_called() == 0)
        gc.GC_init();

    return Allocator{
        .ptr = undefined,
        .vtable = &.{
            .alloc = GcAllocator.alloc,
            .resize = GcAllocator.resize,
            .remap = Allocator.noRemap,
            .free = GcAllocator.free,
        },
    };
}

const GcAllocator = struct {
    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment_: Alignment,
        return_address: usize,
    ) ?[*]u8 {
        _ = return_address;
        assert(len > 0);
        const alignment = alignment_.toByteUnits();
        return @ptrCast(gc.GC_memalign(alignment, len));
    }

    fn resize(
        _: *anyopaque,
        buf: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        _ = alignment;
        _ = return_address;

        if (new_len <= buf.len) return true;
        const full_len = gc.GC_size(buf.ptr);
        if (new_len <= full_len) return true;

        return false;
    }

    fn free(
        _: *anyopaque,
        buf: []u8,
        alignment: Alignment,
        return_address: usize,
    ) void {
        _ = alignment;
        _ = return_address;
        gc.GC_free(buf.ptr);
    }
};

test "basic allocation" {
    const alloc = allocator();

    try std.heap.testAllocator(alloc);
    try std.heap.testAllocatorAligned(alloc);
    try std.heap.testAllocatorLargeAlignment(alloc);
    try std.heap.testAllocatorAlignedShrink(alloc);
}

// BASIC HELPER FUNCTIONS

/// Enable or disable interior pointers.
/// If used, this must be called before the first allocator() call.
pub fn setAllInteriorPointers(enable_interior_pointers: bool) void {
    gc.GC_set_all_interior_pointers(@intFromBool(enable_interior_pointers));
}

/// Returns the current heap size of used memory.
pub fn getHeapSize() u64 {
    return gc.GC_get_heap_size();
}

/// Disable garbage collection.
pub fn disable() void {
    gc.GC_disable();
}

/// Enables garbage collection. GC is enabled by default so this is
/// only useful if you called disable earlier.
pub fn enable() void {
    gc.GC_enable();
}

// Performs a full, stop-the-world garbage collection. With leak detection
// enabled this will output any leaks as well.
pub fn collect() void {
    gc.GC_gcollect();
}

/// Perform some garbage collection. Returns zero when work is done.
pub fn collectLittle() u8 {
    return @as(u8, @intCast(gc.GC_collect_a_little()));
}

/// Enables leak-finding mode. See the libgc docs for more details.
pub fn setFindLeak(v: bool) void {
    return gc.GC_set_find_leak(@intFromBool(v));
}

test "heap size" {
    // No garbage so should be 0
    try testing.expect(collectLittle() == 0);

    // Force a collection should work
    collect();

    try testing.expect(getHeapSize() > 0);
}

// FINALIZERS

/// If enabled, finalizers will only be run in response to an explicit
/// invokeFinalizers() call. Disabled by default.
pub fn setFinalizeOnDemand(value: bool) void {
    gc.GC_set_finalize_on_demand(@intFromBool(value));
}

/// Enable or disable Java finalization. See the libgc docs for more details.
pub fn setJavaFinalization(value: bool) void {
    gc.GC_set_java_finalization(@intFromBool(value));
}

/// The function type for the finalizer notifier.
pub const FinalizerNotifier = *const fn () callconv(.c) void;

/// Invoked by the collector when there are objects to be finalized.
/// Invoked at most once per collection cycle. Never invoked unless
/// finalization is set to run on demand.
pub fn setFinalizerNotifier(notifier: FinalizerNotifier) void {
    gc.GC_set_finalizer_notifier(notifier);
}

/// The function type for finalizers.
/// Data is provided when registered and can be used to determine object type.
pub const Finalizer = *const fn (obj: ?*anyopaque, data: ?*anyopaque) callconv(.c) void;

pub const FinalizerMode = enum {
    /// Perform finalization in the normal order.
    normal,
    /// Ignore pointers from a finalizable object to itself (self-cycles).
    ignore_self,
    /// Ignore all cycles.
    no_order,
    /// Perform finalization when the object is known to be unreachable,
    /// even from other finalizable objects. Only works with Java finalization.
    obj_unreachable,
};

/// Register a finalizer for an object.
/// Finalizers are called prior to deallocation of an object to perform any
/// necessary clean-up, such as closing a file or modifying external state.
pub fn registerFinalizer(
    obj: anytype,
    func: Finalizer,
    data: ?*anyopaque,
    old_func: ?*?Finalizer,
    old_data: ?*?*anyopaque,
    comptime mode: FinalizerMode,
) void {
    const register = switch (mode) {
        .normal => gc.GC_register_finalizer,
        .ignore_self => gc.GC_register_finalizer_ignore_self,
        .no_order => gc.GC_register_finalizer_no_order,
        .obj_unreachable => gc.GC_register_finalizer_unreachable,
    };

    @call(.auto, register, .{ obj, func, data, old_func, old_data });
}

/// Returns true if invokeFinalizers() has something to do.
pub fn shouldInvokeFinalizers() bool {
    return gc.GC_should_invoke_finalizers() > 0;
}

/// Set maximum amount of finalizers to run during a single
/// invokeFinalizers() call. Zero means no limit.
pub fn setInterruptFinalizers(n: usize) void {
    return gc.GC_set_interrupt_finalizers(n);
}

/// Run finalizers for all objects that are ready to be finalized.
/// Returns the number of finalizers that were run.
pub fn invokeFinalizers() usize {
    return @intCast(gc.GC_invoke_finalizers());
}

test "finalizer basics" {
    const FinalizerTest = struct {
        var value: usize = 2;

        fn notifier() callconv(.c) void {
            // decrement the value to show that the notifier ran
            // this should run before the finalizer
            // finalizer will do the same, we'll reach 0
            value -= 1;
        }

        fn finalizer(obj: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
            _ = obj;
            // our data pointer was set to a pointer to `value`
            // decrement the value to show that the finalizer ran
            @as(*volatile usize, @ptrCast(@alignCast(data))).* -= 1;
        }
    };

    // on-demand finalization lets us test:
    // - invokeFinalizers
    // - shouldInvokeFinalizers
    // - setFinalizerNotifier
    setFinalizeOnDemand(true);

    // set a finalizer notifier to modify value
    setFinalizerNotifier(&FinalizerTest.notifier);
    // create an object and register the finalizer on it to modify value
    const obj = try allocator().create(u64);
    registerFinalizer(obj, &FinalizerTest.finalizer, @ptrCast(&FinalizerTest.value), null, null, .normal);
    // destroy the object so bdwgc knows it's unreachable
    allocator().destroy(obj);

    collect();
    collect(); // required for it to be picked up
    try std.testing.expect(shouldInvokeFinalizers());
    try std.testing.expectEqual(1, invokeFinalizers());
    try std.testing.expectEqual(0, FinalizerTest.value);
}
