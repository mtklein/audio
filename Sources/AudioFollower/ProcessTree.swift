import Darwin
import Foundation

// Resolves a PID to the "responsible" PID — the app accountable for its
// actions. For XPC-spawned helpers like Safari's Graphics-and-Media process
// or Chrome's renderer processes, this returns the main browser PID (which
// owns the visible window). Falls through to the input PID if the lookup
// isn't available or the process is already its own responsible PID.
enum ProcessTree {
    static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn = _responsibility else { return pid }
        let result = fn(pid)
        return (result > 0 && result != pid) ? result : pid
    }

    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let _responsibility: Fn? = {
        // RTLD_DEFAULT searches every loaded image. libquarantine is part of
        // libSystem and always loaded in our process.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()
}
