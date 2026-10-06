import XCTest

final class SensorCatalogTests: XCTestCase {
    func testFindsTheCPUAndGPUFamilies() {
        let smc = FakeSMC()
        smc.values["TB0T"] = 30        // battery: a temperature, but not a control sensor
        smc.values["Tf16"] = 200       // a constant that isn't a temperature at all
        let catalog = SensorCatalog.discover(using: smc)
        XCTAssertEqual(catalog.cpuKeys, ["Te05", "Tp01", "Tp05"])
        XCTAssertEqual(catalog.gpuKeys, ["Tg05", "Tg0D"])
        XCTAssertTrue(catalog.allTempKeys.contains("TB0T"))
        XCTAssertFalse(catalog.allTempKeys.contains("Tf16"))
    }

    func testFallsBackToTheKnownKeysWhenAFamilyIsMissing() {
        let smc = FakeSMC()
        smc.setTemps(cpu: nil, gpu: nil)
        smc.values["Tf04"] = 55
        smc.values["Tf14"] = 45
        let catalog = SensorCatalog.discover(using: smc)
        XCTAssertEqual(catalog.cpuKeys, ["Tf04"])
        XCTAssertEqual(catalog.gpuKeys, ["Tf14"])
    }

    func testNamesOnlyWhatItKnows() {
        let smc = FakeSMC()
        smc.values["TB1T"] = 30
        smc.values["TH0x"] = 35
        smc.values["TaLP"] = 33
        let catalog = SensorCatalog.discover(using: smc)
        XCTAssertEqual(catalog.name(of: "Te05"), "CPU sensor 1")
        XCTAssertEqual(catalog.name(of: "Tg0D"), "GPU sensor 2")
        XCTAssertEqual(catalog.name(of: "TB1T"), "Battery")
        XCTAssertEqual(catalog.name(of: "TH0x"), "SSD")
        XCTAssertEqual(catalog.name(of: "TaLP"), "")
    }
}

final class SensorSamplerTests: XCTestCase {
    func testReportsEachGroup() {
        let smc = FakeSMC()
        smc.setTemps(cpu: 50, gpu: 65)
        smc.values["Tp01"] = 70
        smc.values["Tp05"] = 60
        let groups = SensorSampler(smc: smc).sample()
        XCTAssertEqual(groups[.cpuMax], 70)
        XCTAssertEqual(groups[.cpuAverage], 60)
        XCTAssertEqual(groups[.gpuMax], 65)
        XCTAssertEqual(groups[.hottest], 70)
    }

    func testIgnoresReadingsThatCannotBeTemperatures() {
        let smc = FakeSMC()
        let sampler = SensorSampler(smc: smc)
        smc.values["Tp01"] = 250
        smc.values["Tp05"] = -3
        XCTAssertEqual(sampler.sample()[.cpuMax], 50)
    }

    func testPollsOnlyTheHottestKeysBetweenFullPasses() {
        let smc = FakeSMC()
        for i in 0..<20 { smc.values[String(format: "Tp%02d", 10 + i)] = 40 + Double(i) }
        let sampler = SensorSampler(smc: smc)

        smc.clearReads()
        _ = sampler.sample()                                   // full pass
        let cpuKeys = sampler.catalog.cpuKeys.count
        XCTAssertEqual(smc.reads.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }.count, cpuKeys)

        smc.clearReads()
        XCTAssertEqual(sampler.sample()[.cpuMax], 59)          // hottest few only
        XCTAssertEqual(smc.reads.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }.count, 6)

        sampler.reset()
        smc.clearReads()
        _ = sampler.sample()                                   // full again after a reset
        XCTAssertEqual(smc.reads.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }.count, cpuKeys)
    }

    func testAGroupThatCannotBeReadIsAbsent() {
        let smc = FakeSMC()
        let sampler = SensorSampler(smc: smc)
        smc.setTemps(cpu: nil, gpu: nil)
        XCTAssertTrue(sampler.sample().isEmpty)
    }
}
