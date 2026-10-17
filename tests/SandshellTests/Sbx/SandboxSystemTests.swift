import Foundation
import Testing
@testable import Sandshell

/// `SandboxSystem` (Sbx/SandboxSystem.swift): what the in-sandbox probe
/// reports, and the sentence the sandbox popover makes of it.
struct SandboxSystemTests {
    private let probe = """
        kernel=7.0.14-linuxkit
        arch=aarch64
        distro=Ubuntu 26.04.1 LTS
        cpus=8
        memkb=9332456
        mount=/Users/me/Code virtiofs
        """

    @Test func probeOutputIsParsed() throws {
        let system = try #require(SandboxSystem(probeOutput: probe))
        #expect(system.kernel == "7.0.14", "The kernel's build suffix is dropped")
        #expect(system.arch == "aarch64")
        #expect(system.distribution == "Ubuntu 26.04.1 LTS")
        #expect(system.shortDistribution == "Ubuntu 26.04")
        #expect(system.cpus == 8)
        #expect(system.mountTypes == ["/Users/me/Code": "virtiofs"])
    }

    @Test("Memory is GiB to one decimal place, in the user's number format")
    func memoryIsInGiB() throws {
        let system = try #require(SandboxSystem(probeOutput: probe))
        #expect(system.memory == "\(8.9.formatted(.number.precision(.fractionLength(1)))) GiB")
    }

    @Test(.tags(.edgeCase))
    func outputWithoutAKernelIsNoSystem() {
        #expect(SandboxSystem(probeOutput: "arch=aarch64\ncpus=8") == nil)
        #expect(SandboxSystem(probeOutput: "kernel=\narch=aarch64") == nil)
    }

    @Test func detailsListEverythingTheProbeFound() throws {
        let system = try #require(SandboxSystem(probeOutput: probe))
        let memory = try #require(system.memory)
        #expect(system.details == "Linux 7.0.14 (aarch64), Ubuntu 26.04.1 LTS, 8 CPUs, \(memory) memory")
    }

    @Test("One CPU is counted in the singular, and what the probe didn't find is left out", .tags(.edgeCase))
    func detailsWithOneCPUAndNoDistribution() throws {
        let system = try #require(SandboxSystem(probeOutput: "kernel=6.1\narch=x86_64\ndistro=\ncpus=1"))
        #expect(system.details == "Linux 6.1 (x86_64), 1 CPU")
    }

    @Test(.tags(.edgeCase))
    func detailsWithOnlyTheKernel() throws {
        let system = try #require(SandboxSystem(probeOutput: "kernel=6.1\narch=x86_64"))
        #expect(system.details == "Linux 6.1 (x86_64)")
    }
}
