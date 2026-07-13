import SwiftUI

struct AccountEnrollmentPanel: View {
    @ObservedObject var store: RelayMenuStore
    @Binding var isPresented: Bool
    @State private var showsLoginDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加账号")
                        .font(.system(size: 16, weight: .semibold))
                    Text("优先导入当前账号，也可以登录其他账号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            HStack(spacing: 8) {
                Button {
                    store.importCurrentAccount()
                } label: {
                    Label("导入当前账号", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.commandIsRunning || store.isRefreshBusy)

                Button {
                    store.enrollNewAccount()
                } label: {
                    Label("登录其他账号", systemImage: "person.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(store.commandIsRunning || store.isRefreshBusy)

                Spacer()
            }

            if store.commandIsRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.activeProfileCommand == "import-current"
                        ? "正在验证当前账号"
                        : "等待其他账号登录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            enrollmentFeedback

            if showsDeviceLoginDetails {
                VStack(alignment: .leading, spacing: 12) {
                    enrollmentURLRow

                    Divider()

                    enrollmentCodeRow
                }
                .padding(12)
                .liquidGlassSurface(cornerRadius: 12)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Label("读取当前 Codex 已登录的 ChatGPT 订阅账号", systemImage: "person.crop.circle.badge.checkmark")
                    Text("不会退出或重启 ChatGPT。账号凭据仍保存在 CodexDog 的隔离目录中。")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .liquidGlassSurface(cornerRadius: 12)
            }

            if !store.commandOutput.isEmpty {
                DisclosureGroup("操作详情", isExpanded: $showsLoginDetails) {
                    ScrollView {
                        Text(store.commandOutput)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 72)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("完成") {
                    isPresented = false
                }
            }
        }
        .padding(16)
        .frame(minHeight: 270)
    }

    @ViewBuilder
    private var enrollmentFeedback: some View {
        if let feedback = store.accountEnrollmentFeedback {
            switch feedback {
            case .success(let text):
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failure(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
    }

    private var showsDeviceLoginDetails: Bool {
        store.activeProfileCommand == "login"
            || store.enrollmentAuthorizationURL != nil
            || store.enrollmentAuthorizationCode != nil
    }

    private var enrollmentURLRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label("授权地址", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Button {
                    store.openDeviceLogin()
                } label: {
                    Label("打开", systemImage: "arrow.up.forward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.enrollmentAuthorizationURL == nil)
            }

            Text(store.enrollmentAuthorizationURL?.absoluteString ?? "开始登录后显示")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(store.enrollmentAuthorizationURL == nil ? .secondary : .primary)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var enrollmentCodeRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label("一次性验证码", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(store.enrollmentAuthorizationCode ?? "等待生成")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .tracking(store.enrollmentAuthorizationCode == nil ? 0 : 1)
                    .foregroundStyle(store.enrollmentAuthorizationCode == nil ? .secondary : .primary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 4)

            Button {
                store.copyEnrollmentAuthorizationCode()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.enrollmentAuthorizationCode == nil)
        }
    }
}
