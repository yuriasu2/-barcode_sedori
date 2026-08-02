import SwiftUI
import UIKit
import CoreText

/// リンクボタンに載せる1〜2文字のラベル。
///
/// SwiftUIのTextは「行ボックス(ascender〜descender)」の中央で揃うため、
/// 「a」「m」のようにx-heightまでしか占めない字は、字面が枠の中央より下に見える
/// (アセンダ側の余白の方が大きいため)。文字を大きくするほどこのズレは目立つ。
///
/// そこで実際の字面(グリフのインク境界)を測り、その中心が枠の中心に来るよう
/// y方向を補正して描画する。大文字・CJKでは補正量がほぼ0になるため、
/// 全ラベルに同じ処理を通して問題ない。
struct LinkButtonGlyphLabel: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: design))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .offset(y: Self.centeringOffset(text: text, size: size, weight: weight, design: design))
    }

    /// 字面の中心を枠の中心へ合わせるためのyオフセット(正=下へ)。
    private static func centeringOffset(
        text: String,
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design
    ) -> CGFloat {
        let font = uiFont(size: size, weight: weight, design: design)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        // .useGlyphPathBoundsで、行の高さではなく実際に描かれる字面の境界を得る
        // (ベースライン原点・y軸は上向き)。
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard ink.height > 0 else { return 0 }

        // 以下はいずれもベースラインを0とした「y軸下向き」の座標。
        // UIFontのdescenderは負値なので、そのまま足すと行ボックスの中心になる。
        let boxCenter = -(font.ascender + font.descender) / 2
        let inkCenter = -(ink.maxY + ink.minY) / 2
        return boxCenter - inkCenter
    }

    /// 補正量の計算用に、SwiftUIの指定と同じ書体のUIFontを組み立てる。
    private static func uiFont(size: CGFloat, weight: Font.Weight, design: Font.Design) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight(weight))
        guard design == .serif,
              let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .black: return .black
        case .heavy: return .heavy
        case .bold: return .bold
        case .semibold: return .semibold
        case .medium: return .medium
        case .light: return .light
        case .thin: return .thin
        case .ultraLight: return .ultraLight
        default: return .regular
        }
    }
}
