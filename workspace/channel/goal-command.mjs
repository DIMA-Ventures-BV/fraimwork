// fraim-session-command arguments for the session_command tool. The script checks them again.
export function sessionCommandArgs({ command, argument, chat_id: chatId } = {}) {
  const args = chatId ? ['--chat', String(chatId)] : []
  if (command === 'clear') return [...args, 'clear']
  if (command === 'compact') return [...args, 'compact', ...(argument ? [String(argument)] : [])]
  if (command === 'model') return [...args, 'model', String(argument ?? '').trim().toLowerCase()]
  throw new Error('command must be clear, compact or model')
}
