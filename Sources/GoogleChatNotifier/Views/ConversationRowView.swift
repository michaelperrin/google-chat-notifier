import SwiftUI

/// Une entrée de la liste : **un interlocuteur**, le début de son dernier message,
/// l'heure, et une pastille quand plusieurs messages sont non lus.
/// Clic → ouvre la conversation dans Google Chat.
struct ConversationRowView: View {
    let conversation: Conversation

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(conversation.isUnread ? Color.accentColor : Color.secondary)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(conversation.title)
                            .fontWeight(conversation.isUnread ? .semibold : .regular)
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        // Plusieurs messages non lus : on n'affiche qu'une entrée, la pastille
                        // indique combien de messages elle recouvre.
                        if conversation.unreadCount > 1 {
                            Text("\(conversation.unreadCount)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                        }

                        Spacer(minLength: 0)

                        if let lastActive = conversation.lastActive {
                            Text(Self.relativeTime(lastActive))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if let preview = conversation.preview {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help("Ouvrir dans Google Chat")
    }

    private var icon: String {
        if conversation.isGroup { return "person.2" }
        return conversation.isUnread ? "message.badge.fill" : "message"
    }

    private func open() {
        LinkOpener.open(conversation.uri)
    }

    /// « 14:32 » aujourd'hui, « hier », « lun. », sinon la date courte.
    static func relativeTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "hier"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), date > weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
