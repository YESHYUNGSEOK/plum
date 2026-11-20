/// What Plum adds to zsh, the way Ghostty and VS Code do: zsh is started
/// with ZDOTDIR pointing at Plum's folder, whose `.zshenv` puts the user's
/// ZDOTDIR back first thing and reads their own `.zshenv`. Everything after
/// (`.zprofile`, `.zshrc`) is read from the user's folder as always.
///
/// Its one addition: prompts are marked (OSC 133), so the view can jump
/// from command to command. The marks start at the second prompt: hooks
/// are put in place once the first prompt is up, so nothing is printed
/// while the user's own setup runs (Powerlevel10k's instant prompt
/// objects to any output then).
enum ShellIntegration {
    static let zshenv = #"""
    # Written by Plum. Puts your ZDOTDIR back and reads your .zshenv; then
    # marks each prompt (OSC 133) for ⌘↑ / ⌘↓ in Plum.
    if [[ -n "${PLUM_USER_ZDOTDIR+set}" ]]; then
      ZDOTDIR="$PLUM_USER_ZDOTDIR"
    else
      unset ZDOTDIR
    fi
    unset PLUM_USER_ZDOTDIR
    if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
      source "${ZDOTDIR:-$HOME}/.zshenv"
    fi
    if [[ -o interactive ]]; then
      _plum_mark_prompt() { builtin print -n '\e]133;A\a' }
      _plum_mark_output() { builtin print -n '\e]133;C\a' }
      _plum_install_marks() {
        precmd_functions=(${precmd_functions:#_plum_install_marks} _plum_mark_prompt)
        preexec_functions+=(_plum_mark_output)
      }
      precmd_functions+=(_plum_install_marks)
    fi
    """#
}
