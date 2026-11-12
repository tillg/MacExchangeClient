import MailModel
import SwiftUI

/// Help ▸ What's New: the change log, one section per day, newest first.
struct WhatsNewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(WhatsNew.days) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title(day.date)).font(.title3.bold())
                        ForEach(day.features, id: \.self) { feature in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                Text(feature).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func title(_ date: String) -> String {
        guard let d = try? Date(date, strategy: .iso8601.year().month().day()) else { return date }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}
