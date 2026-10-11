//
//  SismikWidget.swift
//  SismikWidget
//
//  Uygulamadaki listenin aynısını (son depremler ve son 24 saatin özeti)
//  gösteren kilit ekranı ve ana ekran widget'ları. Filtreyi uygulamadaki liste
//  belirler; widget'lar ağa çıkmaz. Tümü ücretsizdir.
//

import WidgetKit
import SwiftUI

struct SismikWidget: Widget {
    let kind = "SismikWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SismikWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground(accent: entry.latest.map { WidgetMagnitude.color($0.magnitude) } ?? WidgetTheme.brand)
                }
        }
        .configurationDisplayName(LocalizedStringResource("widget.gallery.recent.title", defaultValue: "Son Depremler"))
        .description(LocalizedStringResource("widget.gallery.recent.desc", defaultValue: "Uygulamadaki listenin aynısı: listede seçtiğin kaynak ve büyüklük filtresi widget'a da uygulanır."))
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}

struct SismikStatsWidget: Widget {
    let kind = "SismikStatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SismikStatsWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground(accent: WidgetTheme.brand)
                }
        }
        .configurationDisplayName(LocalizedStringResource("widget.gallery.stats.title", defaultValue: "Deprem Özeti"))
        .description(LocalizedStringResource("widget.gallery.stats.desc", defaultValue: "Listenin son 24 saati: deprem sayısı, en büyük deprem ve saatlik yoğunluk."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
