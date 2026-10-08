import SwiftUI

/// Emblema do Geleit: estandarte de escolta numa lança (conceito em brand/pennant-concept.png).
/// Vetorial para ficar nítido em qualquer tamanho; a faixa assume a cor do estado da conexão
/// e a bandeira tremula enquanto `waving` estiver ligado.
struct PennantMark: View {
    var stripe: Color = Theme.accent
    var waving = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !waving)) { context in
            let phase = waving ? context.date.timeIntervalSinceReferenceDate * 2.6 : 0.9
            ZStack {
                PennantStaff()
                    .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.62)],
                                         startPoint: .leading, endPoint: .trailing))
                PennantFlag(phase: phase)
                    .fill(LinearGradient(colors: [.white, Color(white: 0.86)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                PennantStripe(phase: phase)
                    .fill(stripe)
                    .mask(PennantFlag(phase: phase))
                PennantFlag(phase: phase)
                    .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .accessibilityHidden(true)
    }
}

/// Coordenadas em uma grade 100×100.
private func pt(_ r: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: r.minX + x / 100 * r.width, y: r.minY + y / 100 * r.height)
}

/// Haste, colar e ponta de lança.
struct PennantStaff: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        // haste
        p.addRoundedRect(in: CGRect(origin: pt(r, 28.6, 22), size: CGSize(width: r.width * 0.044, height: r.height * 0.74)),
                         cornerSize: CGSize(width: r.width * 0.022, height: r.width * 0.022))
        // colar
        p.addRoundedRect(in: CGRect(origin: pt(r, 26.8, 19.5), size: CGSize(width: r.width * 0.08, height: r.height * 0.035)),
                         cornerSize: CGSize(width: r.width * 0.01, height: r.width * 0.01))
        // ponta de lança
        p.move(to: pt(r, 30.8, 2))
        p.addLine(to: pt(r, 34.6, 15))
        p.addLine(to: pt(r, 30.8, 19.5))
        p.addLine(to: pt(r, 27.0, 15))
        p.closeSubpath()
        return p
    }
}

/// Bandeira de duas pontas (rabo de andorinha), ondulada conforme `phase`.
struct PennantFlag: Shape {
    var phase: Double
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in r: CGRect) -> Path {
        let a = CGFloat(sin(phase)) * 3.2
        let b = CGFloat(cos(phase * 1.3)) * 2.6
        var p = Path()
        p.move(to: pt(r, 33, 25))
        p.addCurve(to: pt(r, 95, 31 + b), control1: pt(r, 52, 17 + a), control2: pt(r, 74, 37 - a))
        p.addLine(to: pt(r, 76, 45 + a * 0.6))
        p.addLine(to: pt(r, 91, 62 + b))
        p.addCurve(to: pt(r, 33, 57), control1: pt(r, 72, 66 - a), control2: pt(r, 51, 49 + a))
        p.closeSubpath()
        return p
    }
}

/// Faixa horizontal que acompanha a ondulação da bandeira.
struct PennantStripe: Shape {
    var phase: Double
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in r: CGRect) -> Path {
        let a = CGFloat(sin(phase)) * 3.2
        let b = CGFloat(cos(phase * 1.3)) * 2.6
        var p = Path()
        p.move(to: pt(r, 30, 36))
        p.addCurve(to: pt(r, 100, 41 + b), control1: pt(r, 52, 29 + a), control2: pt(r, 76, 46 - a))
        p.addLine(to: pt(r, 100, 50 + b))
        p.addCurve(to: pt(r, 30, 46), control1: pt(r, 76, 55 - a), control2: pt(r, 52, 39 + a))
        p.closeSubpath()
        return p
    }
}
