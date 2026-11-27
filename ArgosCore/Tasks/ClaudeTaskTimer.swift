//
//  ClaudeTaskTimer.swift
//  ArgosCore
//
//  Temporizador de las tareas programadas: UNA entrada en el sistema que ejecuta
//  `dispatch.sh tick` cada minuto (el despachador decide qué toca). launchd en macOS,
//  systemd --user en Linux y cron si no hay ninguno de los dos. Solo construye comandos
//  (lógica pura; goldens).
//

import Foundation

enum ClaudeTaskTimer {

    static let label = "com.iaportafolio.argos.tasks"
    static let marker = "argos-tasks-timer"

    /// Instala (o reinstala) el temporizador e imprime cuál usó: `launchd`, `systemd`,
    /// `cron` o `none`.
    static let installCommand = #"""
        d="$HOME/.config/argos/tasks/dispatch.sh"
        if [ "$(uname -s)" = Darwin ]; then
          a="$HOME/Library/LaunchAgents"; f="$a/\#(label).plist"
          mkdir -p "$a" && cat > "$f" <<EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\#(label)</string>
          <key>ProgramArguments</key><array><string>/bin/sh</string><string>$d</string><string>tick</string></array>
          <key>StartInterval</key><integer>60</integer>
          <key>RunAtLoad</key><true/>
          <key>StandardOutPath</key><string>/dev/null</string>
          <key>StandardErrorPath</key><string>/dev/null</string>
        </dict></plist>
        EOF
          launchctl bootout "gui/$(id -u)/\#(label)" >/dev/null 2>&1
          launchctl bootstrap "gui/$(id -u)" "$f" >/dev/null 2>&1 \
            || launchctl bootstrap "user/$(id -u)" "$f" >/dev/null 2>&1 \
            || launchctl load -w "$f" >/dev/null 2>&1
          launchctl list 2>/dev/null | grep -q "\#(label)" && { echo launchd; exit 0; }
        fi
        if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
          u="$HOME/.config/systemd/user"; mkdir -p "$u"
          printf '[Unit]\nDescription=Argos: encargos programados\n\n[Service]\nType=oneshot\nExecStart=/bin/sh %s tick\n' "$d" > "$u/argos-tasks.service"
          printf '[Unit]\nDescription=Argos: encargos programados cada minuto\n\n[Timer]\nOnCalendar=*-*-* *:*:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' > "$u/argos-tasks.timer"
          systemctl --user daemon-reload >/dev/null 2>&1
          systemctl --user enable --now argos-tasks.timer >/dev/null 2>&1 && { echo systemd; exit 0; }
        fi
        if command -v crontab >/dev/null 2>&1; then
          { crontab -l 2>/dev/null | grep -v '\#(marker)'; echo "* * * * * /bin/sh \"$d\" tick >/dev/null 2>&1 # \#(marker)"; } | crontab - \
            && { echo cron; exit 0; }
        fi
        echo none
        """#

    /// Imprime qué temporizador está activo (`launchd`, `systemd`, `cron` o `none`).
    static let statusCommand = #"""
        if [ "$(uname -s)" = Darwin ] && launchctl list 2>/dev/null | grep -q "\#(label)"; then echo launchd; exit 0; fi
        if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active argos-tasks.timer >/dev/null 2>&1; then echo systemd; exit 0; fi
        if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q '\#(marker)'; then echo cron; exit 0; fi
        echo none
        """#

    /// Quita el temporizador (lo que haya de los tres).
    static let uninstallCommand = #"""
        if [ "$(uname -s)" = Darwin ]; then
          launchctl bootout "gui/$(id -u)/\#(label)" >/dev/null 2>&1 || launchctl unload "$HOME/Library/LaunchAgents/\#(label).plist" >/dev/null 2>&1
          rm -f "$HOME/Library/LaunchAgents/\#(label).plist"
        fi
        if command -v systemctl >/dev/null 2>&1; then
          systemctl --user disable --now argos-tasks.timer >/dev/null 2>&1
          rm -f "$HOME/.config/systemd/user/argos-tasks.timer" "$HOME/.config/systemd/user/argos-tasks.service"
        fi
        if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q '\#(marker)'; then
          crontab -l 2>/dev/null | grep -v '\#(marker)' | crontab -
        fi
        exit 0
        """#

    enum Kind: String, Equatable, Sendable {
        case launchd, systemd, cron, none
    }

    static func parse(_ output: String) -> Kind {
        output.split(whereSeparator: \.isNewline).reversed()
            .compactMap { Kind(rawValue: $0.trimmingCharacters(in: .whitespaces)) }.first ?? .none
    }
}
