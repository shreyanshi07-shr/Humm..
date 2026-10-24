-- =====================================================================
--  humm.. · database setup for Supabase
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run again: it only adds what's missing.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- tables ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default '' check (char_length(name) <= 40),
  city       text check (char_length(city) <= 80),
  lat        double precision,
  lon        double precision,
  tz         text check (char_length(tz) <= 64),
  created_at timestamptz not null default now()
);

create table if not exists public.couples (
  id             uuid primary key default gen_random_uuid(),
  a              uuid not null references auth.users(id) on delete cascade,  -- whoever set it up
  b              uuid references auth.users(id) on delete set null,           -- the person who joined
  invite_code    text not null unique,
  invite_name    text check (char_length(invite_name) <= 40),
  invite_contact text check (char_length(invite_contact) <= 120),
  created_at     timestamptz not null default now(),
  constraint couple_two_people check (b is null or a <> b)
);
create unique index if not exists couples_one_per_a on public.couples(a);
-- what each of you calls the other: nick_a is a's name for b, nick_b is b's name for a
alter table public.couples add column if not exists nick_a text check (char_length(nick_a) <= 40);
alter table public.couples add column if not exists nick_b text check (char_length(nick_b) <= 40);
create unique index if not exists couples_one_per_b on public.couples(b) where b is not null;

create table if not exists public.songs (
  id         uuid primary key default gen_random_uuid(),
  couple_id  uuid not null references public.couples(id) on delete cascade,
  added_by   uuid references auth.users(id) on delete set null,
  title      text not null check (char_length(title) between 1 and 120),
  artist     text check (char_length(artist) <= 120),
  duration   integer check (duration between 0 and 7200),
  audio_path text not null,
  cover_path text,
  tint       jsonb,
  created_at timestamptz not null default now()
);
create index if not exists songs_by_couple on public.songs(couple_id, created_at desc);
-- songs can also stream from YouTube (no file)
alter table public.songs add column if not exists source text not null default 'file';
alter table public.songs add column if not exists yt_id text;
alter table public.songs alter column audio_path drop not null;
do $$ begin
  alter table public.songs add constraint songs_has_audio check (audio_path is not null or yt_id ~ '^[A-Za-z0-9_-]{11}$');
exception when duplicate_object then null; end $$;

create table if not exists public.playlists (
  id         uuid primary key default gen_random_uuid(),
  couple_id  uuid not null references public.couples(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists playlists_by_couple on public.playlists(couple_id, created_at);

create table if not exists public.playlist_songs (
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  song_id     uuid not null references public.songs(id) on delete cascade,
  couple_id   uuid not null references public.couples(id) on delete cascade,
  added_by    uuid references auth.users(id) on delete set null,
  position    double precision not null default extract(epoch from clock_timestamp()),
  primary key (playlist_id, song_id)
);
create index if not exists playlist_songs_by_couple on public.playlist_songs(couple_id);

create table if not exists public.notes (
  id         uuid primary key default gen_random_uuid(),
  couple_id  uuid not null references public.couples(id) on delete cascade,
  author     uuid not null references auth.users(id) on delete cascade,
  song_id    uuid references public.songs(id) on delete cascade,   -- empty = a little note on Home
  body       text not null check (char_length(body) between 1 and 500),
  re         text check (char_length(re) <= 500),
  created_at timestamptz not null default now()
);
create index if not exists notes_by_couple on public.notes(couple_id, created_at);

-- ---------- helpers (run with owner rights, used by the rules below) ----------
create or replace function public.my_couple() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.couples where a = auth.uid() or b = auth.uid() limit 1
$$;

create or replace function public.in_my_couple(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select uid = auth.uid() or exists (
    select 1 from public.couples
    where (a = auth.uid() or b = auth.uid()) and (a = uid or b = uid))
$$;

create or replace function public.new_invite_code() returns text
language plpgsql volatile set search_path = public as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  code text;
begin
  loop
    code := 'HUM-';
    for i in 1..4 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.couples where invite_code = code);
  end loop;
  return code;
end $$;

-- ---------- row level security: you only ever see your own two-person world ----------
alter table public.profiles enable row level security;
alter table public.couples  enable row level security;
alter table public.songs    enable row level security;
alter table public.notes    enable row level security;
alter table public.playlists      enable row level security;
alter table public.playlist_songs enable row level security;

drop policy if exists "profiles: me and my person" on public.profiles;
create policy "profiles: me and my person" on public.profiles
  for select to authenticated using (public.in_my_couple(id));
drop policy if exists "profiles: create mine" on public.profiles;
create policy "profiles: create mine" on public.profiles
  for insert to authenticated with check (id = auth.uid());
drop policy if exists "profiles: edit mine" on public.profiles;
create policy "profiles: edit mine" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "couples: mine" on public.couples;
create policy "couples: mine" on public.couples
  for select to authenticated using (a = auth.uid() or b = auth.uid());
drop policy if exists "couples: edit invite" on public.couples;
create policy "couples: edit invite" on public.couples
  for update to authenticated using (a = auth.uid()) with check (a = auth.uid());
-- only the invite details can be edited directly; pairing happens through join_couple()
revoke update on public.couples from authenticated, anon;
grant update (invite_name, invite_contact) on public.couples to authenticated;
revoke insert, delete on public.couples from authenticated, anon;

drop policy if exists "songs: our library" on public.songs;
create policy "songs: our library" on public.songs
  for select to authenticated using (couple_id = public.my_couple());
drop policy if exists "songs: add to ours" on public.songs;
create policy "songs: add to ours" on public.songs
  for insert to authenticated with check (couple_id = public.my_couple() and added_by = auth.uid());
drop policy if exists "songs: remove from ours" on public.songs;
create policy "songs: remove from ours" on public.songs
  for delete to authenticated using (couple_id = public.my_couple());

drop policy if exists "notes: ours" on public.notes;
create policy "notes: ours" on public.notes
  for select to authenticated using (couple_id = public.my_couple());
drop policy if exists "notes: write" on public.notes;
create policy "notes: write" on public.notes
  for insert to authenticated with check (couple_id = public.my_couple() and author = auth.uid());
drop policy if exists "notes: unsend mine" on public.notes;
create policy "notes: unsend mine" on public.notes
  for delete to authenticated using (author = auth.uid());

drop policy if exists "playlists: ours" on public.playlists;
create policy "playlists: ours" on public.playlists
  for all to authenticated
  using (couple_id = public.my_couple())
  with check (couple_id = public.my_couple());

drop policy if exists "playlist songs: ours" on public.playlist_songs;
create policy "playlist songs: ours" on public.playlist_songs
  for all to authenticated
  using (couple_id = public.my_couple())
  with check (couple_id = public.my_couple()
    and exists (select 1 from public.playlists p where p.id = playlist_id and p.couple_id = public.my_couple())
    and exists (select 1 from public.songs s where s.id = song_id and s.couple_id = public.my_couple()));

-- ---------- actions the app calls ----------

-- your own little corner (made the first time you need it)
create or replace function public.ensure_couple() returns public.couples
language plpgsql security definer set search_path = public as $$
declare c public.couples;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into c from public.couples where a = auth.uid() or b = auth.uid() limit 1;
  if not found then
    insert into public.couples (a, invite_code) values (auth.uid(), public.new_invite_code()) returning * into c;
  end if;
  return c;
end $$;

-- who sent this invite? (shown on the join screen, even before signing up)
create or replace function public.invite_info(code text)
returns table (inviter_name text, inviter_city text, open boolean)
language sql stable security definer set search_path = public as $$
  select p.name, p.city, c.b is null
  from public.couples c join public.profiles p on p.id = c.a
  where c.invite_code = upper(trim(code))
$$;

-- accept an invite: you join their corner (anything you'd added on your own comes with you)
create or replace function public.join_couple(code text) returns public.couples
language plpgsql security definer set search_path = public as $$
declare c public.couples; mine public.couples;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into c from public.couples where invite_code = upper(trim(code)) for update;
  if not found then raise exception 'invite_not_found'; end if;
  if c.a = auth.uid() then raise exception 'own_invite'; end if;
  if c.b = auth.uid() then return c; end if;
  if c.b is not null then raise exception 'invite_used'; end if;
  if exists (select 1 from public.couples where b = auth.uid()) then raise exception 'already_paired'; end if;
  select * into mine from public.couples where a = auth.uid();
  if found then
    if mine.b is not null then raise exception 'already_paired'; end if;
    update public.songs set couple_id = c.id where couple_id = mine.id;
    update public.notes set couple_id = c.id where couple_id = mine.id;
    update public.playlists set couple_id = c.id where couple_id = mine.id;
    update public.playlist_songs set couple_id = c.id where couple_id = mine.id;
    delete from public.couples where id = mine.id;
  end if;
  update public.couples set b = auth.uid() where id = c.id returning * into c;
  return c;
end $$;

-- rename your person, just for you
create or replace function public.set_nickname(nick text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update public.couples set nick_a = nullif(left(trim(nick), 40), '') where a = auth.uid();
  update public.couples set nick_b = nullif(left(trim(nick), 40), '') where b = auth.uid();
end $$;

-- delete my account and everything that's only mine
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
declare c public.couples; me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into c from public.couples where a = me or b = me limit 1;
  if found then
    delete from public.songs where couple_id = c.id and added_by = me;
    if c.a = me and c.b is not null then
      update public.couples set a = c.b, b = null, invite_code = public.new_invite_code(),
        invite_name = null, invite_contact = null, nick_a = null, nick_b = null where id = c.id;
    elsif c.b = me then
      update public.couples set b = null, invite_code = public.new_invite_code(),
        invite_name = null, invite_contact = null, nick_a = null, nick_b = null where id = c.id;
    end if;
  end if;
  delete from auth.users where id = me;   -- profile, notes and a solo corner go with it
end $$;

revoke all on function public.ensure_couple()      from public, anon;
revoke all on function public.join_couple(text)    from public, anon;
revoke all on function public.delete_my_account()  from public, anon;
grant execute on function public.ensure_couple()      to authenticated;
grant execute on function public.join_couple(text)    to authenticated;
grant execute on function public.delete_my_account()  to authenticated;
revoke all on function public.set_nickname(text) from public, anon;
grant execute on function public.set_nickname(text) to authenticated;
grant execute on function public.invite_info(text)    to anon, authenticated;
revoke all on function public.new_invite_code() from public, anon, authenticated;

-- ---------- phone notifications (web push): each phone that turned them on ----------
create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  sub        jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists "push: mine" on public.push_subscriptions;
create policy "push: mine" on public.push_subscriptions
  for all to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
-- a phone that changes hands moves to whoever is signed in on it now
create or replace function public.save_push(p_endpoint text, p_sub jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into public.push_subscriptions(endpoint, owner, sub) values (p_endpoint, auth.uid(), p_sub)
  on conflict (endpoint) do update set owner = auth.uid(), sub = excluded.sub, created_at = now();
end $$;
revoke all on function public.save_push(text, jsonb) from public, anon;
grant execute on function public.save_push(text, jsonb) to authenticated;

-- ---------- live updates ----------
do $$ begin
  begin alter publication supabase_realtime add table public.notes;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.songs;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.couples; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.playlists; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.playlist_songs; exception when duplicate_object then null; end;
end $$;

-- ---------- song files: each person uploads into their own folder; only the two of you can play them ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('songs', 'songs', false, 31457280, array['audio/mpeg','audio/mp3','audio/mp4','audio/x-m4a','audio/aac','audio/wav','audio/ogg','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "songs files: upload to my folder" on storage.objects;
create policy "songs files: upload to my folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'songs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "songs files: play ours" on storage.objects;
create policy "songs files: play ours" on storage.objects
  for select to authenticated
  using (bucket_id = 'songs' and public.in_my_couple(((storage.foldername(name))[1])::uuid));
drop policy if exists "songs files: remove ours" on storage.objects;
create policy "songs files: remove ours" on storage.objects
  for delete to authenticated
  using (bucket_id = 'songs' and public.in_my_couple(((storage.foldername(name))[1])::uuid));
