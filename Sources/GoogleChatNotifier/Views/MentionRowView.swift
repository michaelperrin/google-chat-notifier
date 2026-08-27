import SwiftUI

/// Une entrée de l'onglet « Mentions » : le salon, l'auteur, le début du message.
/// Clic → ouvre le salon dans Google Chat.
struct MentionRowView: View {
    let mention: Mention

    var body: some View {
        Button(action: { LinkOpener.open(mention.uri) }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: mention.isGroup ? "person.2.fill" : "at")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mention.spaceTitle)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        if let date = mention.date {
                            Text(ConversationRowView.relativeTime(date))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // L'auteur est porté par l'aperçu : dans un salon, savoir qui m'a
                    // cité compte autant que ce qui a été dit.
                    Text("\(mention.authorName) : \(mention.preview)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help("Ouvrir le salon dans Google Chat")
    }
}
