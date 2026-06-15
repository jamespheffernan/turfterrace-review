import SwiftUI

struct QueueView: View {
  @ObservedObject var store: ReviewStore
  @State private var showingSettings = false

  var body: some View {
    VStack(spacing: 0) {
      header
      tabPicker
      if let banner = store.bannerMessage {
        BannerView(message: banner, isWarning: store.isUsingDemoData)
          .padding(.horizontal, 14)
          .padding(.bottom, 8)
      }
      list
    }
    .background(TurfTheme.paper)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          Task { await store.refresh() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(store.isLoading)
        .accessibilityLabel("Refresh queue")

        Button {
          showingSettings = true
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .accessibilityLabel("Settings")
      }
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView(configuration: store.configuration) { configuration in
        await store.saveConfiguration(configuration)
        showingSettings = false
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Circle()
          .fill(store.isUsingDemoData ? TurfTheme.gold : TurfTheme.moss)
          .frame(width: 10, height: 10)
        Text(store.isUsingDemoData ? "Demo mode" : store.configuration.displayURL)
          .font(.caption.weight(.semibold))
          .foregroundStyle(TurfTheme.muted)
          .lineLimit(1)
        Spacer()
        if store.isLoading {
          ProgressView()
            .controlSize(.small)
        }
      }

      Text("Review queue")
        .font(.system(.largeTitle, design: .serif, weight: .bold))
        .foregroundStyle(TurfTheme.ink)

      Text("Decide, annotate, ask, and inspect downstream proof from one native queue.")
        .font(.subheadline)
        .foregroundStyle(TurfTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(18)
  }

  private var tabPicker: some View {
    Picker("Queue", selection: Binding(
      get: { store.selectedTab },
      set: { tab in
        Task { await store.selectTab(tab) }
      }
    )) {
      ForEach(ReviewTab.allCases) { tab in
        Text("\(tab.title) \(store.counts[tab] ?? 0)").tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
  }

  private var list: some View {
    List(selection: Binding(
      get: { store.selectedSlug },
      set: { slug in
        Task { await store.selectItem(slug: slug) }
      }
    )) {
      if store.visibleItems.isEmpty {
        ContentUnavailableView(
          emptyStateTitle,
          systemImage: emptyStateSystemImage,
          description: Text(emptyStateDescription)
        )
        .listRowBackground(Color.clear)
      } else {
        ForEach(store.visibleItems) { item in
          NavigationLink(value: item.slug) {
            QueueRow(item: item)
          }
          .tag(item.slug)
          .listRowBackground(Color.clear)
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if store.selectedTab == .pending,
               let archiveAction = item.archiveAction {
              Button {
                Task { await store.submitDecision(for: item.slug, archiveAction, feedback: "") }
              } label: {
                Label("Archive", systemImage: "archivebox.fill")
              }
              .tint(TurfTheme.muted)
              .disabled(store.isSubmittingDecision(slug: item.slug))
            }
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .listStyle(.plain)
    .refreshable {
      await store.refresh()
    }
  }

  private var isInitialLoading: Bool {
    store.isLoading && store.items.isEmpty
  }

  private var emptyStateTitle: String {
    isInitialLoading ? "Loading queue" : "No \(store.selectedTab.title.lowercased()) items"
  }

  private var emptyStateSystemImage: String {
    isInitialLoading ? "arrow.clockwise" : "tray"
  }

  private var emptyStateDescription: String {
    isInitialLoading
      ? "Fetching reviews from \(store.configuration.displayURL)."
      : "Pull the latest queue when the server has new reviews."
  }
}

struct QueueRow: View {
  let item: ReviewItem

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(TurfTheme.statusColor(item.status))
        .frame(width: 6, height: 44)

      VStack(alignment: .leading, spacing: 7) {
        Text(item.title)
          .font(.headline)
          .foregroundStyle(TurfTheme.ink)
          .lineLimit(3)

        HStack(spacing: 8) {
          BadgeText(item.category.uppercased(), color: TurfTheme.plum)
          Text(item.contentLengthLabel)
            .font(.caption)
            .foregroundStyle(TurfTheme.muted)
          Text(item.createdAt?.prefix(10) ?? "No date")
            .font(.caption)
            .foregroundStyle(TurfTheme.muted)
        }

        if let decision = item.decision, !decision.isEmpty {
          Text(decision)
            .font(.caption.weight(.semibold))
            .foregroundStyle(TurfTheme.statusColor(item.status))
        }

        if let message = item.effectiveActionMessage, item.effectiveActionStatus != "succeeded" {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(TurfTheme.coral)
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, 8)
  }
}

struct BadgeText: View {
  let text: String
  let color: Color

  init(_ text: String, color: Color) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(.caption2.weight(.bold))
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(color.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

struct BannerView: View {
  let message: String
  let isWarning: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: isWarning ? "wifi.slash" : "info.circle.fill")
      Text(message)
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .foregroundStyle(isWarning ? TurfTheme.gold : TurfTheme.accent)
    .padding(10)
    .background((isWarning ? TurfTheme.gold : TurfTheme.accent).opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}
