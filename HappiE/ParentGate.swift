//
//  ParentGate.swift
//  HappiE
//
//  Created for HappiE.
//

import SwiftUI

/// The classic kids-app parental gate: digits are written out as words, so
/// the grown-up has to read them and type the numbers. Pre-readers can't
/// get through by guessing or mashing.
struct ParentGateView: View {
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var challenge = ParentGateChallenge.random()
    @State private var typed: [Int] = []
    @State private var attemptFailed = false

    var body: some View {
        ScrollView {
            gateContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HTheme.background)
    }

    private var gateContent: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(HTheme.muted)

                Text("Grown-ups only")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(HTheme.ink)

                Text("Type the numbers: **\(challenge.spelledOut)**")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(HTheme.muted)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { index in
                    Text(index < typed.count ? "\(typed[index])" : "")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(HTheme.ink)
                        .frame(width: 58, height: 68)
                        .background(HTheme.surface)
                        .clipShape(.rect(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(attemptFailed ? HTheme.accent : HTheme.line, lineWidth: 2)
                        )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Entered \(typed.count) of 3 digits")

            if attemptFailed {
                Text("Not quite — try the new numbers.")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(HTheme.accent)
            }

            keypad

            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(HTheme.muted)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var keypad: some View {
        let rows: [[Int]] = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
        return VStack(spacing: 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { digit in
                        keypadButton(digit)
                    }
                }
            }
            HStack(spacing: 12) {
                Color.clear.frame(width: 76, height: 60)
                keypadButton(0)
                Button {
                    if !typed.isEmpty {
                        typed.removeLast()
                    }
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(HTheme.muted)
                        .frame(width: 76, height: 60)
                }
                .accessibilityLabel("Delete last digit")
            }
        }
    }

    private func keypadButton(_ digit: Int) -> some View {
        Button {
            enter(digit)
        } label: {
            Text("\(digit)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(HTheme.ink)
                .frame(width: 76, height: 60)
                .background(HTheme.surface)
                .clipShape(.rect(cornerRadius: 14))
        }
    }

    private func enter(_ digit: Int) {
        guard typed.count < 3 else { return }
        attemptFailed = false
        typed.append(digit)

        guard typed.count == 3 else { return }
        if typed == challenge.digits {
            dismiss()
            onSuccess()
        } else {
            attemptFailed = true
            typed = []
            challenge = ParentGateChallenge.random()
        }
    }
}

struct ParentGateChallenge {
    let digits: [Int]

    static func random() -> ParentGateChallenge {
        ParentGateChallenge(digits: (0..<3).map { _ in Int.random(in: 1...9) })
    }

    var spelledOut: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        return digits
            .map { formatter.string(from: NSNumber(value: $0)) ?? "\($0)" }
            .joined(separator: " · ")
    }
}
