import SwiftUI
import QpasteCore

struct DateRangeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState<Date> private var start: Date
    @ViewState<Date> private var end: Date
    let apply: (HistoryDateFilter) -> Void

    init(selection: HistoryDateFilter, apply: @escaping (HistoryDateFilter) -> Void) {
        let today = Calendar.current.startOfDay(for: Date())
        if case .custom(let start, let end) = selection {
            _start = ViewState(initialValue: start)
            _end = ViewState(initialValue: end)
        } else {
            _start = ViewState(initialValue: selection.interval()?.start ?? Calendar.current.date(byAdding: .day, value: -6, to: today)!)
            _end = ViewState(initialValue: today)
        }
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("选择日期范围").font(.system(size: 17, weight: .semibold))
            DatePicker("起始日期", selection: $start, displayedComponents: .date).datePickerStyle(.field)
            DatePicker("结束日期", selection: $end, displayedComponents: .date).datePickerStyle(.field)
            HStack {
                Text("包含起止两天").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") {
                    apply(.custom(start: start, end: end))
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end))
            }
        }.padding(24).frame(width: 340).tint(Palette.accent)
            .environment(\.locale, Locale(identifier: "zh_CN"))
    }
}
