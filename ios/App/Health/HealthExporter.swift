import CoreLocation
import Foundation
import HealthKit
import Zone2Kit

/// HKWorkout → HealthKitDump (lossless enough to recompute everything server-side; docs/05-sync.md §6).
struct HealthExporter {
    let store: HKHealthStore

    /// Quantity series we export: identifier → (dump key, unit, unit label).
    static let series: [(HKQuantityTypeIdentifier, String, HKUnit, String)] = [
        (.heartRate, "heartRate", HKUnit.count().unitDivided(by: .minute()), "count/min"),
        (.distanceWalkingRunning, "distanceWalkingRunning", .meter(), "m"),
        (.distanceCycling, "distanceCycling", .meter(), "m"),
        (.distanceSwimming, "distanceSwimming", .meter(), "m"),
        (.swimmingStrokeCount, "swimmingStrokeCount", .count(), "count"),
        (.runningPower, "runningPower", .watt(), "W"),
        (.runningSpeed, "runningSpeed", HKUnit.meter().unitDivided(by: .second()), "m/s"),
        (.runningStrideLength, "runningStrideLength", .meter(), "m"),
        (.runningVerticalOscillation, "runningVerticalOscillation", .meterUnit(with: .centi), "cm"),
        (.runningGroundContactTime, "runningGroundContactTime", .secondUnit(with: .milli), "ms"),
        (.cyclingPower, "cyclingPower", .watt(), "W"),
        (.cyclingCadence, "cyclingCadence", HKUnit.count().unitDivided(by: .minute()), "count/min"),
        (.cyclingSpeed, "cyclingSpeed", HKUnit.meter().unitDivided(by: .second()), "m/s"),
        (.activeEnergyBurned, "activeEnergyBurned", .kilocalorie(), "kcal"),
        (.stepCount, "stepCount", .count(), "count"),
    ]

    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for (id, _, _, _) in series { types.insert(HKQuantityType(id)) }
        for id: HKQuantityTypeIdentifier in [.restingHeartRate, .heartRateVariabilitySDNN, .vo2Max, .bodyMass] {
            types.insert(HKQuantityType(id))
        }
        types.insert(HKCategoryType(.sleepAnalysis))
        return types
    }

    func dump(_ workout: HKWorkout, appVersion: String) async throws -> HealthKitDump {
        let start = workout.startDate
        let off = { (d: Date) in d.timeIntervalSince(start) }
        let predicate = HKQuery.predicateForObjects(from: workout)

        var samples: [String: HealthKitDump.SampleSeries] = [:]
        for (id, key, unit, label) in Self.series {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )
            let result = try await descriptor.result(for: store)
            guard !result.isEmpty else { continue }
            samples[key] = .init(unit: label, values: result.map {
                [off($0.startDate), off($0.endDate), $0.quantity.doubleValue(for: unit)]
            })
        }

        var route: [[Double]] = []
        let routes = try await HKSampleQueryDescriptor(
            predicates: [.workoutRoute(predicate)], sortDescriptors: [SortDescriptor(\.startDate)]
        ).result(for: store)
        for r in routes {
            for try await p in HKWorkoutRouteQueryDescriptor(r).results(for: store) {
                route.append([off(p.timestamp), p.coordinate.latitude, p.coordinate.longitude, p.altitude,
                              p.horizontalAccuracy, p.verticalAccuracy, p.speed, p.course])
            }
        }

        let distance = [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
            .compactMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter()) }
            .first
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?
            .doubleValue(for: .kilocalorie())

        return HealthKitDump(
            exportedAt: DumpTime.string(.now),
            app: .init(version: appVersion),
            workout: .init(
                uuid: workout.uuid.uuidString,
                activityType: Int(workout.workoutActivityType.rawValue),
                start: DumpTime.string(workout.startDate),
                end: DumpTime.string(workout.endDate),
                durationSec: workout.duration,
                totalDistanceM: distance,
                totalEnergyKcal: energy,
                source: .init(name: workout.sourceRevision.source.name,
                              bundleId: workout.sourceRevision.source.bundleIdentifier),
                device: workout.device.map {
                    .init(name: $0.name, model: $0.model, hardwareVersion: $0.hardwareVersion,
                          softwareVersion: $0.softwareVersion)
                },
                metadata: Self.metadata(workout.metadata),
                activities: workout.workoutActivities.map { a in
                    .init(uuid: a.uuid.uuidString,
                          activityType: Int(a.workoutConfiguration.activityType.rawValue),
                          start: DumpTime.string(a.startDate),
                          end: a.endDate.map(DumpTime.string),
                          location: Self.location(a.workoutConfiguration.locationType),
                          metadata: Self.metadata(a.metadata))
                },
                events: (workout.workoutEvents ?? []).map { e in
                    .init(type: Self.eventName(e.type),
                          start: DumpTime.string(e.dateInterval.start),
                          end: DumpTime.string(e.dateInterval.end),
                          metadata: Self.metadata(e.metadata))
                }
            ),
            samples: samples,
            route: route
        )
    }

    static func location(_ t: HKWorkoutSessionLocationType) -> String {
        switch t {
        case .indoor: "indoor"
        case .outdoor: "outdoor"
        default: "unknown"
        }
    }

    static func eventName(_ t: HKWorkoutEventType) -> String {
        switch t {
        case .pause: "pause"
        case .resume: "resume"
        case .lap: "lap"
        case .marker: "marker"
        case .motionPaused: "motionPaused"
        case .motionResumed: "motionResumed"
        case .segment: "segment"
        case .pauseOrResumeRequest: "pauseOrResumeRequest"
        @unknown default: "unknown"
        }
    }

    /// Quantities are converted to a known unit and labelled (temperature → °C, humidity → %).
    static func metadata(_ meta: [String: Any]?) -> [String: HealthKitDump.MetaValue] {
        let units: [(HKUnit, String)] = [
            (.degreeCelsius(), "degC"), (.percent(), "%"), (.meter(), "m"),
            (HKUnit.count().unitDivided(by: .minute()), "count/min"), (.kilocalorie(), "kcal"),
            (.second(), "s"), (HKUnit(from: "kcal/hr·kg"), "kcal/hr·kg"),
        ]
        var out: [String: HealthKitDump.MetaValue] = [:]
        for (key, value) in meta ?? [:] {
            switch value {
            case let q as HKQuantity:
                if let (unit, label) = units.first(where: { q.is(compatibleWith: $0.0) }) {
                    out[key] = .quantity(value: q.doubleValue(for: unit), unit: label)
                } else {
                    out[key] = .string(q.description)
                }
            case let n as NSNumber:
                out[key] = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
            case let s as String:
                out[key] = .string(s)
            case let d as Date:
                out[key] = .string(DumpTime.string(d))
            default:
                out[key] = .string(String(describing: value))
            }
        }
        return out
    }
}
