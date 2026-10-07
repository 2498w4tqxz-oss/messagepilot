import { DatabaseSync } from "node:sqlite";
import { homedir } from "node:os";
import { join } from "node:path";
/** Admin enrollment only. Resolve one supplied address, never enumerate the inbox. */
export function resolveDirectChat(
  recipient: string,
  database = join(homedir(), "Library/Messages/chat.db"),
) {
  if (
    !/^\+[1-9]\d{7,14}$/.test(recipient) &&
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)
  )
    throw new Error("Use an exact E.164 phone number or email address");
  const db = new DatabaseSync(database, { readOnly: true });
  try {
    const rows = db
      .prepare(
        `SELECT c.guid AS chatId,c.chat_identifier AS recipient,c.service_name AS service
   FROM chat c JOIN chat_handle_join j ON j.chat_id=c.ROWID JOIN handle h ON h.ROWID=j.handle_id
   WHERE h.id=? COLLATE NOCASE AND c.service_name='iMessage'
   AND (SELECT COUNT(*) FROM chat_handle_join j2 WHERE j2.chat_id=c.ROWID)=1 LIMIT 2`,
      )
      .all(recipient);
    if (rows.length !== 1)
      throw new Error(
        "Expected one existing direct iMessage chat for this exact recipient; enrollment refused",
      );
    return rows[0]!;
  } finally {
    db.close();
  }
}
