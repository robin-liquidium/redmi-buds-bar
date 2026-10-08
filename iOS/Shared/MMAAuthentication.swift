// SPDX-License-Identifier: GPL-3.0-or-later
// Xiaomi MMA challenge response, adapted from BudsLink's authentication research.
// See ThirdPartyNotices.txt and ../COPYING for attribution and licensing.
import Foundation

// The protocol uses a modified SAFER+ round function with a fixed protocol seed.
// Its response has been independently matched against a captured Xiaomi app session.
enum MMAAuthentication {
    static func response(to challenge: [UInt8]) -> [UInt8]? {
        guard challenge.count == 16 else { return nil }
        var exponent = [UInt8](repeating: 0, count: 256)
        var logarithm = exponent
        var power = 1
        for i in 0..<256 {
            exponent[i] = UInt8(power % 256)
            logarithm[Int(exponent[i])] = UInt8(i)
            power = power * 45 % 257
        }
        var key = challenge
        key[15] ^= 6
        var keys = [key]
        var register = key + [key.reduce(0, ^)]
        for round in 1...16 {
            register = register.map { ($0 << 3) | ($0 >> 5) }
            keys.append((0..<16).map { i in
                let bias = exponent[Int(exponent[(17 * (round + 1) + i + 1) % 256])]
                return register[(round + i) % 17] &+ bias
            })
        }
        let seed: [UInt8] = [0x11, 0x22, 0x33, 0x33, 0x22, 0x11, 0x11, 0x22,
                             0x33, 0x33, 0x22, 0x11, 0x11, 0x22, 0x33, 0x33]
        var state = seed
        for round in 0..<8 {
            for i in 0..<16 {
                let xor = (0x9999 >> i) & 1 != 0
                if round == 2 { state[i] = xor ? state[i] ^ seed[i] : state[i] &+ seed[i] }
                state[i] = xor ? state[i] ^ keys[round * 2][i] : state[i] &+ keys[round * 2][i]
                state[i] = xor ? exponent[Int(state[i])] : logarithm[Int(state[i])]
                state[i] = xor ? state[i] &+ keys[round * 2 + 1][i] : state[i] ^ keys[round * 2 + 1][i]
            }
            let input = state
            state = mixing.map { row in
                UInt8(truncatingIfNeeded: zip(row, input).reduce(0) { $0 + $1.0 * Int($1.1) })
            }
        }
        return (0..<16).map { i in
            (0x9999 >> i) & 1 != 0 ? state[i] ^ keys[16][i] : state[i] &+ keys[16][i]
        }
    }

    private static let mixing: [[Int]] = [

    [2, 1, 1, 1, 4, 2, 1, 1, 2, 2, 4, 2, 4, 4, 16, 8],
    [2, 1, 1, 1, 4, 2, 1, 1, 1, 1, 2, 1, 2, 2, 8, 4],
    [1, 1, 4, 2, 2, 2, 4, 2, 16, 8, 4, 4, 2, 1, 1, 1],
    [1, 1, 4, 2, 1, 1, 2, 1, 8, 4, 2, 2, 2, 1, 1, 1],
    [16, 8, 2, 2, 4, 2, 4, 4, 1, 1, 4, 2, 1, 1, 2, 1],
    [8, 4, 1, 1, 2, 1, 2, 2, 1, 1, 4, 2, 1, 1, 2, 1],
    [2, 2, 4, 2, 4, 4, 16, 8, 2, 1, 1, 1, 4, 2, 1, 1],
    [1, 1, 2, 1, 2, 2, 8, 4, 2, 1, 1, 1, 4, 2, 1, 1],
    [4, 2, 4, 4, 16, 8, 2, 2, 1, 1, 2, 1, 1, 1, 4, 2],
    [2, 1, 2, 2, 8, 4, 1, 1, 1, 1, 2, 1, 1, 1, 4, 2],
    [4, 4, 16, 8, 1, 1, 2, 1, 4, 2, 1, 1, 4, 2, 2, 2],
    [2, 2, 8, 4, 1, 1, 2, 1, 4, 2, 1, 1, 2, 1, 1, 1],
    [1, 1, 2, 1, 1, 1, 4, 2, 4, 4, 16, 8, 2, 2, 4, 2],
    [1, 1, 2, 1, 1, 1, 4, 2, 2, 2, 8, 4, 1, 1, 2, 1],
    [4, 2, 1, 1, 2, 1, 1, 1, 4, 2, 2, 2, 16, 8, 4, 4],
    [4, 2, 1, 1, 2, 1, 1, 1, 2, 1, 1, 1, 8, 4, 2, 2],
    ]
}
