import SwiftUI

/// The robot avatars kids pick (`robot-1` … `robot-12`): a colour and a face. Unknown names show robot 1.
public struct RobotAvatarStyle: Equatable, Sendable {
    public let index: Int

    public init(avatar: String) {
        let number = Int(avatar.replacingOccurrences(of: "robot-", with: "")) ?? 1
        index = (1 ... 12).contains(number) ? number : 1
    }

    public static let all = (1 ... 12).map { RobotAvatarStyle(avatar: "robot-\($0)") }

    private static let hues: [Double] = [0.58, 0.02, 0.33, 0.12, 0.78, 0.48, 0.92, 0.66, 0.08, 0.40, 0.85, 0.17]

    var color: Color {
        Color(hue: Self.hues[index - 1], saturation: 0.55, brightness: 0.92)
    }

    /// Round eyes for odd robots, square for even ones; every third has a big smile.
    var roundEyes: Bool {
        index % 2 == 1
    }

    var bigSmile: Bool {
        index % 3 == 0
    }
}

/// A friendly robot head drawn with shapes (no images), so it scales to any size and works in dark mode.
public struct RobotAvatarView: View {
    let style: RobotAvatarStyle
    let size: CGFloat

    public init(avatar: String, size: CGFloat) {
        style = RobotAvatarStyle(avatar: avatar)
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(style.color.gradient)
            VStack(spacing: size * 0.08) {
                HStack(spacing: size * 0.16) {
                    eye
                    eye
                }
                Capsule()
                    .fill(.white)
                    .frame(width: size * (style.bigSmile ? 0.38 : 0.26), height: size * 0.07)
            }
            .offset(y: size * 0.05)
            Circle()
                .fill(.white)
                .frame(width: size * 0.1)
                .offset(y: -size * 0.42)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var eye: some View {
        Group {
            if style.roundEyes {
                Circle().fill(.white)
            } else {
                RoundedRectangle(cornerRadius: size * 0.03).fill(.white)
            }
        }
        .frame(width: size * 0.16, height: size * 0.16)
    }
}
