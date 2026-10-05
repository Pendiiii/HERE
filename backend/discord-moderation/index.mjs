import {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
  Client,
  EmbedBuilder,
  GatewayIntentBits,
  PermissionFlagsBits,
  SlashCommandBuilder,
} from 'discord.js';
import pg from 'pg';

const required = [
  'DATABASE_URL', 'DISCORD_BOT_TOKEN', 'DISCORD_APPLICATION_ID', 'DISCORD_GUILD_ID',
  'DISCORD_STAFF_CHANNEL_ID', 'DISCORD_STAFF_ROLE_ID', 'DISCORD_SUPPORT_FORUM_ID',
  'SUPABASE_STORAGE_URL', 'SUPABASE_SERVICE_ROLE_KEY',
];
for (const key of required) {
  if (!process.env[key]) throw new Error(`Missing environment variable: ${key}`);
}

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
const storageBaseURL = process.env.SUPABASE_STORAGE_URL.replace(/\/+$/, '');
const storageHeaders = {
  apikey: process.env.SUPABASE_SERVICE_ROLE_KEY,
  authorization: `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,
};
const client = new Client({ intents: [
  GatewayIntentBits.Guilds,
  GatewayIntentBits.GuildMessages,
  GatewayIntentBits.MessageContent,
] });
const pollInterval = Number(process.env.REPORT_POLL_INTERVAL_MS ?? 5000);
let polling = false;
let supportPolling = false;

const sanctionCommand = new SlashCommandBuilder()
  .setName('here-sanction')
  .setDescription('HERE-Nutzer sanktionieren oder Sanktionen aufheben')
  .addStringOption(option => option.setName('aktion').setDescription('Aktion').setRequired(true).addChoices(
    { name: 'Mute', value: 'mute' }, { name: 'Mute aufheben', value: 'unmute' },
    { name: 'Ban', value: 'ban' }, { name: 'Ban aufheben', value: 'unban' },
  ))
  .addStringOption(option => option.setName('nutzer').setDescription('HERE User UUID').setRequired(true))
  .addIntegerOption(option => option.setName('minuten').setDescription('Mute-Dauer').setMinValue(1).setMaxValue(43200))
  .addStringOption(option => option.setName('grund').setDescription('Interne Begründung').setMaxLength(300));

function isStaff(interaction) {
  const roles = interaction.member?.roles;
  const hasStaffRole = roles?.cache?.has?.(process.env.DISCORD_STAFF_ROLE_ID)
    || (Array.isArray(roles) && roles.includes(process.env.DISCORD_STAFF_ROLE_ID));
  return hasStaffRole
    || interaction.memberPermissions?.has(PermissionFlagsBits.Administrator);
}

function reportButtons(reportId, disabled = false) {
  return [new ActionRowBuilder().addComponents(
    new ButtonBuilder().setCustomId(`here:dismiss:${reportId}`).setLabel('Freigeben').setStyle(ButtonStyle.Secondary).setDisabled(disabled),
    new ButtonBuilder().setCustomId(`here:delete:${reportId}`).setLabel('Inhalt löschen').setStyle(ButtonStyle.Danger).setDisabled(disabled),
    new ButtonBuilder().setCustomId(`here:mute60:${reportId}`).setLabel('Mute 1h').setStyle(ButtonStyle.Primary).setDisabled(disabled),
    new ButtonBuilder().setCustomId(`here:mute1440:${reportId}`).setLabel('Mute 24h').setStyle(ButtonStyle.Primary).setDisabled(disabled),
    new ButtonBuilder().setCustomId(`here:ban:${reportId}`).setLabel('Bannen').setStyle(ButtonStyle.Danger).setDisabled(disabled),
  )];
}

function supportButtons(ticketId, disabled = false) {
  return [new ActionRowBuilder().addComponents(
    new ButtonBuilder().setCustomId(`here:supportclose:${ticketId}`).setLabel('Ticket beenden').setStyle(ButtonStyle.Danger).setDisabled(disabled),
  )];
}

function storageObjectURL(bucket, path, access = '') {
  const encodedPath = path.split('/').map(encodeURIComponent).join('/');
  const accessPath = access ? `/${access}` : '';
  return `${storageBaseURL}/object${accessPath}/${bucket}/${encodedPath}`;
}

async function downloadSupportFiles(paths = []) {
  const files = [];
  for (const [index, path] of paths.slice(0, 4).entries()) {
    const response = await fetch(storageObjectURL('here-support-media', path, 'authenticated'), { headers: storageHeaders });
    if (!response.ok) throw new Error(`Support-Bild konnte nicht geladen werden (${response.status})`);
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > 5 * 1024 * 1024) continue;
    const extension = path.split('.').pop()?.toLowerCase() || 'jpg';
    files.push({ attachment: buffer, name: `support-bild-${index + 1}.${extension}` });
  }
  return files;
}

async function uploadSupportFile(attachment, userId, ticketId) {
  const contentType = (attachment.contentType ?? '').split(';')[0].toLowerCase();
  const extension = ({ 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' })[contentType];
  if (!extension || attachment.size > 5 * 1024 * 1024) return null;
  const response = await fetch(attachment.url);
  if (!response.ok) throw new Error(`Discord-Bild konnte nicht geladen werden (${response.status})`);
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length > 5 * 1024 * 1024) return null;
  const path = `users/${userId}/support/${ticketId}/${crypto.randomUUID()}.${extension}`;
  const uploaded = await fetch(storageObjectURL('here-support-media', path), {
    method: 'POST',
    headers: { ...storageHeaders, 'content-type': contentType, 'x-upsert': 'false' },
    body: buffer,
  });
  if (!uploaded.ok) throw new Error(`Support-Bild konnte nicht gespeichert werden (${uploaded.status})`);
  return path;
}

async function pendingSupportTickets() {
  const { rows } = await pool.query(`
    select t.id, t.status, t.discord_thread_id, p.display_name,
           first_message.id as first_message_id, first_message.body as first_message,
           first_message.image_paths as first_message_images
      from public.support_tickets t
      left join public.profiles p on p.id = t.user_id
      left join lateral (
        select m.id, m.body, m.image_paths from public.support_messages m
         where m.ticket_id = t.id and m.sender = 'user' order by m.created_at, m.id limit 1
      ) first_message on true
     where t.status in ('pending', 'open', 'closing')
     order by t.created_at
  `);
  return rows;
}

async function closeSupportTicket(ticket) {
  if (ticket.discord_thread_id) {
    try {
      const thread = await client.channels.fetch(ticket.discord_thread_id);
      if (thread) await thread.delete('HERE Support-Ticket beendet');
    } catch (error) {
      if (error?.code !== 10003) throw error;
    }
  }
  await pool.query(`update public.support_tickets set status = 'closed', closed_at = now(), updated_at = now()
                     where id = $1 and status = 'closing'`, [ticket.id]);
  await pool.query(`delete from public.support_tickets where id = $1 and user_id is null`, [ticket.id]);
}

async function publishSupportTickets() {
  if (supportPolling || !client.isReady()) return;
  supportPolling = true;
  try {
  const forum = await client.channels.fetch(process.env.DISCORD_SUPPORT_FORUM_ID);
  if (!forum?.isThreadOnly()) throw new Error('Support channel is not a forum channel');

  for (const ticket of await pendingSupportTickets()) {
    if (ticket.status === 'closing') {
      await closeSupportTicket(ticket);
      continue;
    }

    let thread;
    if (!ticket.discord_thread_id) {
      if (!ticket.first_message) continue;
      thread = await forum.threads.create({
        name: `Support · ${ticket.display_name ?? 'Gelöschter Nutzer'} · ${ticket.id.slice(0, 8)}`.slice(0, 100),
        message: {
          content: `<@&${process.env.DISCORD_STAFF_ROLE_ID}>\n**HERE Support-Ticket**\nNutzer: **${ticket.display_name ?? 'Gelöschter Nutzer'}**\nTicket: \`${ticket.id}\`\nTeam: einfach direkt in diesem Post schreiben.\n\n**Nachricht**\n${ticket.first_message}`,
          components: supportButtons(ticket.id),
          allowedMentions: { roles: [process.env.DISCORD_STAFF_ROLE_ID] },
          files: await downloadSupportFiles(ticket.first_message_images ?? []),
        },
        reason: 'Neues HERE Support-Ticket',
      });
      const starter = await thread.fetchStarterMessage();
      const db = await pool.connect();
      try {
        await db.query('begin');
        await db.query(`update public.support_tickets set status = 'open', discord_thread_id = $2, updated_at = now()
                           where id = $1 and status = 'pending'`, [ticket.id, thread.id]);
        await db.query(`update public.support_messages set discord_message_id = $2 where id = $1 and discord_message_id is null`,
                         [ticket.first_message_id, starter?.id ?? thread.id]);
        await db.query('commit');
      } catch (error) {
        await db.query('rollback');
        await thread.delete('Ticket konnte nicht gespeichert werden').catch(() => {});
        throw error;
      } finally {
        db.release();
      }
    } else {
      thread = await client.channels.fetch(ticket.discord_thread_id);
    }

    if (!thread?.isTextBased()) continue;
    const starter = await thread.fetchStarterMessage();
    const hasOldReplyButton = starter?.components.some(row => row.components.some(component =>
      component.customId?.startsWith('here:supportreply:')));
    const hasOldReplyInstruction = starter?.content.includes('Zum Antworten den Button **Antworten** verwenden.');
    if (starter && (hasOldReplyButton || hasOldReplyInstruction)) {
      await starter.edit({
        content: starter.content.replace('Zum Antworten den Button **Antworten** verwenden.', 'Team: direkt in diesem Post schreiben.'),
        components: supportButtons(ticket.id),
      });
    }
    const { rows: outbound } = await pool.query(`
      select id, body, image_paths from public.support_messages
       where ticket_id = $1 and sender = 'user' and discord_message_id is null order by created_at, id
    `, [ticket.id]);
    for (const message of outbound) {
      const discordMessage = await thread.send({ content: `**Nutzer**\n${message.body}`,
        files: await downloadSupportFiles(message.image_paths ?? []), allowedMentions: { parse: [] } });
      await pool.query(`update public.support_messages set discord_message_id = $2
                         where id = $1 and discord_message_id is null`, [message.id, discordMessage.id]);
    }
  }
  } finally {
    supportPolling = false;
  }
}

async function pendingReports() {
  const { rows } = await pool.query(`
    select rep.id, rep.target_type, rep.target_id, rep.reason, rep.created_at,
           reporter.display_name as reporter_name,
           coalesce(p.author_id, rr.author_id) as target_user_id,
           coalesce(p.body, rr.body) as content,
           target_profile.display_name as target_name
      from public.reports rep
      join public.profiles reporter on reporter.id = rep.reporter_id
      left join public.posts p on rep.target_type = 'post' and p.id = rep.target_id
      left join public.replies rr on rep.target_type = 'reply' and rr.id = rep.target_id
      left join public.profiles target_profile on target_profile.id = coalesce(p.author_id, rr.author_id)
     where rep.status = 'pending'
     order by rep.created_at
     limit 20
  `);
  return rows;
}

async function publishReports() {
  if (polling || !client.isReady()) return;
  polling = true;
  try {
    const channel = await client.channels.fetch(process.env.DISCORD_STAFF_CHANNEL_ID);
    if (!channel?.isTextBased()) throw new Error('Staff channel is not text based');
    for (const report of await pendingReports()) {
      const embed = new EmbedBuilder()
        .setColor(0xE65C4F)
        .setTitle(`HERE Report · ${report.reason}`)
        .setDescription((report.content ?? '[Inhalt nicht mehr verfügbar]').slice(0, 2000))
        .addFields(
          { name: 'Fall-ID', value: report.id },
          { name: 'Gemeldeter Nutzer', value: `${report.target_name ?? 'Unbekannt'}\n\`${report.target_user_id ?? 'nicht verfügbar'}\`` },
          { name: 'Gemeldet von', value: report.reporter_name },
          { name: 'Typ', value: report.target_type, inline: true },
        )
        .setTimestamp(new Date(report.created_at))
        .setFooter({ text: 'Standorte werden niemals an Discord übertragen.' });
      const message = await channel.send({ embeds: [embed], components: reportButtons(report.id) });
      await pool.query(
        `update public.reports set status = 'queued', discord_message_id = $2 where id = $1 and status = 'pending'`,
        [report.id, message.id],
      );
    }
  } finally {
    polling = false;
  }
}

async function resolveReport(reportId, action, actorId) {
  const db = await pool.connect();
  try {
    await db.query('begin');
    const { rows } = await db.query(`
      select rep.*, coalesce(p.author_id, rr.author_id) as target_user_id
        from public.reports rep
        left join public.posts p on rep.target_type = 'post' and p.id = rep.target_id
        left join public.replies rr on rep.target_type = 'reply' and rr.id = rep.target_id
       where rep.id = $1 for update of rep
    `, [reportId]);
    const report = rows[0];
    if (!report) throw new Error('Report not found');
    if (!report.target_user_id && action !== 'dismiss') throw new Error('Target user no longer exists');

    let resolution = action;
    if (action === 'delete') {
      const table = report.target_type === 'post' ? 'posts' : 'replies';
      await db.query(`update public.${table} set deleted_at = now() where id = $1`, [report.target_id]);
    } else if (action === 'mute60' || action === 'mute1440') {
      const minutes = action === 'mute60' ? 60 : 1440;
      await db.query(`insert into public.sanctions(user_id, kind, reason, created_by, expires_at)
                      values ($1, 'mute', $2, $3, now() + ($4::integer * interval '1 minute'))`,
                     [report.target_user_id, `Discord report: ${report.reason}`, actorId, minutes]);
      resolution = `mute_${minutes}m`;
    } else if (action === 'ban') {
      await db.query(`insert into public.sanctions(user_id, kind, reason, created_by)
                      values ($1, 'ban', $2, $3)`,
                     [report.target_user_id, `Discord report: ${report.reason}`, actorId]);
    }

    const status = action === 'dismiss' ? 'dismissed' : 'resolved';
    await db.query(`update public.reports set status = $2, reviewed_by = $3, reviewed_at = now(), resolution = $4 where id = $1`,
                   [reportId, status, actorId, resolution]);
    await db.query(`insert into public.moderation_actions(report_id, target_user_id, action, actor_discord_id, details)
                    values ($1, $2, $3, $4, jsonb_build_object('reason', $5::text))`,
                   [reportId, report.target_user_id, resolution, actorId, report.reason]);
    await db.query('commit');
    return resolution;
  } catch (error) {
    await db.query('rollback');
    throw error;
  } finally {
    db.release();
  }
}

async function executeSanctionCommand(interaction) {
  const action = interaction.options.getString('aktion', true);
  const userId = interaction.options.getString('nutzer', true);
  const minutes = interaction.options.getInteger('minuten') ?? 60;
  const reason = interaction.options.getString('grund') ?? 'Manuelle Staff-Entscheidung';
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)) {
    return interaction.reply({ content: 'Ungültige HERE User UUID.', ephemeral: true });
  }
  const db = await pool.connect();
  try {
    await db.query('begin');
    const exists = await db.query('select 1 from public.profiles where id = $1', [userId]);
    if (!exists.rowCount) throw new Error('HERE user not found');
    if (action === 'mute') {
      await db.query(`insert into public.sanctions(user_id, kind, reason, created_by, expires_at)
                      values ($1, 'mute', $2, $3, now() + ($4::integer * interval '1 minute'))`,
                     [userId, reason, interaction.user.id, minutes]);
    } else if (action === 'ban') {
      await db.query(`insert into public.sanctions(user_id, kind, reason, created_by)
                      values ($1, 'ban', $2, $3)`, [userId, reason, interaction.user.id]);
    } else {
      const kind = action === 'unmute' ? 'mute' : 'ban';
      await db.query(`update public.sanctions set revoked_at = now(), revoked_by = $2
                       where user_id = $1 and kind = $3 and revoked_at is null
                         and (expires_at is null or expires_at > now())`, [userId, interaction.user.id, kind]);
    }
    await db.query(`insert into public.moderation_actions(target_user_id, action, actor_discord_id, details)
                    values ($1, $2, $3, jsonb_build_object('reason', $4::text, 'minutes', $5::integer))`,
                   [userId, action, interaction.user.id, reason, action === 'mute' ? minutes : null]);
    await db.query('commit');
    await interaction.reply({ content: `Aktion **${action}** für \`${userId}\` gespeichert.`, ephemeral: true });
  } catch (error) {
    await db.query('rollback');
    await interaction.reply({ content: `Aktion fehlgeschlagen: ${error.message}`, ephemeral: true });
  } finally {
    db.release();
  }
}

client.once('clientReady', async () => {
  await client.application.commands.set([sanctionCommand.toJSON()], process.env.DISCORD_GUILD_ID);
  await pool.query('select 1');
  await Promise.all([publishReports(), publishSupportTickets()]);
  setInterval(() => publishReports().catch(console.error), pollInterval);
  setInterval(() => publishSupportTickets().catch(console.error), pollInterval);
  console.log(`HERE moderation ready as ${client.user.tag}`);
});

client.on('messageCreate', async message => {
  if (message.author.bot || message.guildId !== process.env.DISCORD_GUILD_ID
      || message.channel.parentId !== process.env.DISCORD_SUPPORT_FORUM_ID) return;

  const hasStaffRole = message.member?.roles?.cache?.has(process.env.DISCORD_STAFF_ROLE_ID);
  const isAdministrator = message.member?.permissions?.has(PermissionFlagsBits.Administrator);
  if (!hasStaffRole && !isAdministrator) return;

  const body = message.content.trim();
  const supportedAttachments = [...message.attachments.values()].filter(attachment =>
    ['image/jpeg', 'image/png', 'image/webp'].includes((attachment.contentType ?? '').split(';')[0].toLowerCase())
    && attachment.size <= 5 * 1024 * 1024).slice(0, 4);
  if (!body && !supportedAttachments.length) return;
  if (body.length > 1500) {
    await message.reply({
      content: 'Diese Nachricht wurde nicht in HERE übertragen. Bitte kürze sie auf höchstens 1500 Zeichen.',
      allowedMentions: { repliedUser: false },
    });
    return;
  }

  const staffName = (message.member?.displayName ?? message.author.globalName ?? message.author.username).slice(0, 80);
  try {
    const ticketResult = await pool.query(`select id, user_id from public.support_tickets
      where discord_thread_id = $1 and status = 'open'`, [message.channel.id]);
    const ticket = ticketResult.rows[0];
    if (!ticket) return;
    const imagePaths = [];
    for (const attachment of supportedAttachments) {
      const path = await uploadSupportFile(attachment, ticket.user_id, ticket.id);
      if (path) imagePaths.push(path);
    }
    const messageBody = body || (imagePaths.length ? 'Bild' : '');
    if (!messageBody) {
      await message.reply({ content: 'Bitte sende JPEG-, PNG- oder WebP-Bilder bis 5 MB.', allowedMentions: { repliedUser: false } });
      return;
    }
    const { rowCount } = await pool.query(`
      with ticket as (
        update public.support_tickets
           set assigned_staff_id = coalesce(assigned_staff_id, $2),
               assigned_staff_name = coalesce(assigned_staff_name, $3), updated_at = now()
         where id = $1 and status = 'open'
         returning id
      )
      insert into public.support_messages(ticket_id, sender, body, image_paths, staff_discord_id, staff_display_name, discord_message_id)
      select ticket.id, 'staff', $4, $5, $2, $3, $6 from ticket
      on conflict (discord_message_id) do nothing
    `, [ticket.id, message.author.id, staffName, messageBody, imagePaths, message.id]);
    if (rowCount) console.log('Staff support message relayed', message.channel.id);
  } catch (error) {
    console.error('Could not relay staff support message', error);
  }
});

client.on('interactionCreate', async interaction => {
  if (!isStaff(interaction)) {
    if (interaction.isRepliable()) await interaction.reply({ content: 'Keine Berechtigung.', ephemeral: true });
    return;
  }
  if (interaction.isChatInputCommand() && interaction.commandName === 'here-sanction') {
    await executeSanctionCommand(interaction);
    return;
  }
  if (!interaction.isButton() || !interaction.customId.startsWith('here:')) return;
  if (interaction.customId.startsWith('here:supportclose:')) {
    const ticketId = interaction.customId.split(':')[2];
    try {
      const result = await pool.query(`update public.support_tickets set status = 'closing', updated_at = now()
                                        where id = $1 and status in ('pending', 'open') returning id, discord_thread_id`, [ticketId]);
      if (!result.rowCount) throw new Error('Ticket ist bereits beendet');
      await interaction.reply({ content: 'Ticket wird beendet und dieser Forumspost gelöscht.', ephemeral: true });
      await closeSupportTicket({ id: ticketId, discord_thread_id: result.rows[0].discord_thread_id });
    } catch (error) {
      if (!interaction.replied) await interaction.reply({ content: `Aktion fehlgeschlagen: ${error.message}`, ephemeral: true });
    }
    return;
  }
  const [, action, reportId] = interaction.customId.split(':');
  try {
    const resolution = await resolveReport(reportId, action, interaction.user.id);
    await interaction.update({ components: reportButtons(reportId, true) });
    await interaction.followUp({ content: `Fall abgeschlossen: **${resolution}**`, ephemeral: true });
  } catch (error) {
    await interaction.reply({ content: `Aktion fehlgeschlagen: ${error.message}`, ephemeral: true });
  }
});

async function shutdown() {
  await client.destroy();
  await pool.end();
  process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

await client.login(process.env.DISCORD_BOT_TOKEN);
