-- Minilist: kişiselleştirme, fotoğraflar ve şifreli sayfa
-- ÖNCE 01_guvenlik_ve_istatistik.sql çalıştırılmış olmalı.
-- Supabase > SQL Editor'da bir kez çalıştırın. Tekrar çalıştırmak güvenlidir.
-- Bu dosya misafir fonksiyonlarının imzasını değiştirir: yeni index.html ile birlikte yayınlayın.

begin;

create extension if not exists pgcrypto with schema extensions;

-- 1) Yeni alanlar --------------------------------------------------------------
alter table public.pages add column if not exists greeting text;
alter table public.pages add column if not exists name_story text;
alter table public.pages add column if not exists sibling text;
alter table public.pages add column if not exists palette text;
alter table public.pages add column if not exists cover_path text;
alter table public.pages add column if not exists pw_hash text;
alter table public.updates add column if not exists photo_path text;
alter table public.letters add column if not exists relation text;
alter table public.reservations add column if not exists relation text;

alter table public.pages drop constraint if exists pages_greeting_len;
alter table public.pages add constraint pages_greeting_len check (length(greeting) <= 600);
alter table public.pages drop constraint if exists pages_name_story_len;
alter table public.pages add constraint pages_name_story_len check (length(name_story) <= 600);
alter table public.pages drop constraint if exists pages_sibling_len;
alter table public.pages add constraint pages_sibling_len check (length(sibling) <= 80);
alter table public.pages drop constraint if exists pages_palette_ok;
alter table public.pages add constraint pages_palette_ok check (palette in ('lilac', 'rose', 'sea', 'sage', 'apricot'));
-- Fotoğraf yolu sadece "<bu sayfanın id'si>/<uuid>.jpg" olabilir: başka sayfanın dosyası ya da dış URL yazılamaz.
alter table public.pages drop constraint if exists pages_cover_path_ok;
alter table public.pages add constraint pages_cover_path_ok check (
  cover_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$' and split_part(cover_path, '/', 1) = id::text);
alter table public.updates drop constraint if exists updates_photo_path_ok;
alter table public.updates add constraint updates_photo_path_ok check (
  photo_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$' and split_part(photo_path, '/', 1) = page_id::text);

alter table public.letters drop constraint if exists letters_relation_ok;
alter table public.letters add constraint letters_relation_ok check (relation in
  ('anneanne', 'babaanne', 'dede', 'teyze', 'hala', 'dayi', 'amca', 'kuzen', 'kardes', 'arkadas'));
alter table public.reservations drop constraint if exists reservations_relation_ok;
alter table public.reservations add constraint reservations_relation_ok check (relation in
  ('anneanne', 'babaanne', 'dede', 'teyze', 'hala', 'dayi', 'amca', 'kuzen', 'kardes', 'arkadas'));

-- 2) Korunan alanlara pw_hash eklendi: şifre sadece set_page_password ile değişir.
create or replace function public.protect_page_cols()
 returns trigger
 language plpgsql
 security invoker
 set search_path to 'public'
as $$
begin
  if current_user in ('anon', 'authenticated') and not is_admin() then
    if tg_op = 'INSERT' then
      new.plan := 'free';
      new.plan_source := null;
      new.pw_hash := null;
    elsif new.id is distinct from old.id
       or new.owner is distinct from old.owner
       or new.slug is distinct from old.slug
       or new.plan is distinct from old.plan
       or new.plan_source is distinct from old.plan_source
       or new.created_at is distinct from old.created_at
       or new.pw_hash is distinct from old.pw_hash then
      raise exception 'Bu alan değiştirilemez';
    end if;
  end if;
  return new;
end $$;

-- 3) Sayfa şifresi -------------------------------------------------------------
-- Boş şifre = şifreyi kaldır. Şifre bcrypt ile özetlenir, düz metin hiçbir yerde tutulmaz.
create or replace function public.set_page_password(pid uuid, p_pw text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
begin
  if auth.uid() is null or not is_owner(pid) then raise exception 'forbidden'; end if;
  if p_pw is null or p_pw = '' then
    update pages set pw_hash = null where id = pid;
  elsif length(p_pw) not between 4 and 100 then
    raise exception 'Şifre 4 ile 100 karakter arasında olmalı';
  else
    update pages set pw_hash = extensions.crypt(p_pw, extensions.gen_salt('bf', 10)) where id = pid;
  end if;
end $$;
revoke execute on function public.set_page_password(uuid, text) from public, anon;
grant execute on function public.set_page_password(uuid, text) to authenticated;

-- rate_ok ile aynı IP kaynağı (deneme sayımı için).
create or replace function public.client_ip()
 returns text
 language sql
 stable
 set search_path to 'public'
as $$ select coalesce(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), '') $$;

-- Şifre doğru mu? Sahip için her zaman true. Yanlış denemeler rate_log'a yazılır ve
-- saatte 30 denemeden sonra (misafir işlemleriyle ortak sayaç) şifre hiç denenmez.
create or replace function public.page_pw_ok(g pages, p_pw text)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public'
as $$
begin
  if g.pw_hash is null or is_owner(g.id) then return true; end if;
  if p_pw is null or length(p_pw) > 100 then return false; end if;
  if (select count(*) from rate_log where ip = client_ip() and page_id = g.id and at > now() - interval '1 hour') >= 30 then
    raise exception 'Çok fazla deneme, lütfen daha sonra tekrar deneyin';
  end if;
  if extensions.crypt(p_pw, g.pw_hash) = g.pw_hash then return true; end if;
  insert into rate_log(ip, page_id) values (client_ip(), g.id);
  return false;
end $$;
revoke execute on function public.page_pw_ok(pages, text) from public, anon, authenticated;

-- 4) get_page: şifre kontrolü + yeni alanlar --------------------------------------
drop function if exists public.get_page(text);
drop function if exists public.get_page(text, text);
create function public.get_page(p_slug text, p_pw text default null)
 returns jsonb
 language plpgsql
 volatile security definer
 set search_path to 'public'
as $$
declare g pages;
begin
  select * into g from pages where slug = p_slug;
  if not found then return null; end if;
  if not page_pw_ok(g, p_pw) then
    -- Kilitliyken sadece görünüm için gereken en az bilgi döner; ad, tarih, içerik yok.
    return jsonb_build_object('locked', true, 'wrong', p_pw is not null,
      'lang', g.lang, 'theme', g.theme, 'palette', g.palette);
  end if;
  return jsonb_build_object(
    'page', (to_jsonb(g) - 'owner' - 'plan_source' - 'pw_hash') || jsonb_build_object('has_pw', g.pw_hash is not null),
    'products', coalesce((select jsonb_agg(to_jsonb(p) order by p.id) from products p where p.page_id = g.id), '[]'::jsonb),
    'totals', coalesce((select jsonb_agg(jsonb_build_object('product_id', r.product_id, 'qty', r.qty, 'amt', r.amt))
        from (select product_id,
                     coalesce(sum(case when amount = 0 then quantity end), 0)::int as qty,
                     coalesce(sum(amount), 0) as amt
              from reservations
              where product_id in (select id from products where page_id = g.id)
              group by product_id) r), '[]'::jsonb),
    'updates', coalesce((select jsonb_agg(to_jsonb(u) order by u.id desc) from updates u where u.page_id = g.id), '[]'::jsonb),
    'letters', case when g.letters_open_at is not null and g.letters_open_at <= current_date
        then coalesce((select jsonb_agg(jsonb_build_object('name', l.name, 'body', l.body, 'relation', l.relation) order by l.id)
                       from letters l where l.page_id = g.id), '[]'::jsonb)
        else '[]'::jsonb end,
    'guesses', case when g.born
        then coalesce((select jsonb_agg(to_jsonb(s) order by s.id) from guesses s where s.page_id = g.id), '[]'::jsonb)
        else '[]'::jsonb end);
end $$;

-- 5) Misafir fonksiyonları: şifre parametresi. Eski imzalar silinir ki
--    şifreyi atlayan bir arka kapı kalmasın.
drop function if exists public.guest_page(text);
drop function if exists public.guest_page(text, text);
create function public.guest_page(p_slug text, p_pw text default null)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare g pages;
begin
  select * into g from pages where slug = p_slug;
  if not found then raise exception 'not found'; end if;
  if not rate_ok(g.id) then raise exception 'Çok fazla deneme, lütfen daha sonra tekrar deneyin'; end if;
  if not page_pw_ok(g, p_pw) then raise exception 'Sayfa şifresi gerekli'; end if;
  return g.id;
end $$;
revoke execute on function public.guest_page(text, text) from public, anon, authenticated;

drop function if exists public.guest_letter(text, text, text);
drop function if exists public.guest_letter(text, text, text, text, text);
create function public.guest_letter(p_slug text, p_name text, p_body text, p_rel text default null, p_pw text default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 80
     or length(trim(coalesce(p_body, ''))) not between 1 and 1000 then
    raise exception 'invalid';
  end if;
  insert into letters(page_id, name, body, relation)
  values (guest_page(p_slug, p_pw), trim(p_name), trim(p_body), nullif(p_rel, ''));
end $$;

drop function if exists public.guest_reserve(text, bigint, text, text, integer, numeric);
drop function if exists public.guest_reserve(text, bigint, text, text, integer, numeric, text, text);
create function public.guest_reserve(p_slug text, p_product bigint, p_name text, p_note text, p_qty integer, p_amount numeric,
                                     p_rel text default null, p_pw text default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare pid uuid;
begin
  pid := guest_page(p_slug, p_pw);
  if not exists (select 1 from products where id = p_product and page_id = pid) then raise exception 'not found'; end if;
  if p_amount < 0 or p_amount > 100000 or p_qty < 1 or p_qty > 50 or length(coalesce(p_name, '')) not between 1 and 80
    then raise exception 'invalid'; end if;
  insert into reservations(product_id, name, note, quantity, amount, relation)
  values (p_product, p_name, left(p_note, 300), p_qty, p_amount, nullif(p_rel, ''));
end $$;

drop function if exists public.guest_suggest(text, text, text, text);
drop function if exists public.guest_suggest(text, text, text, text, text);
create function public.guest_suggest(p_slug text, p_name text, p_from text, p_note text, p_pw text default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare pid uuid;
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 60
     or length(trim(coalesce(p_from, ''))) not between 1 and 80
     or length(coalesce(p_note, '')) > 200 then
    raise exception 'invalid';
  end if;
  pid := guest_page(p_slug, p_pw);
  if (select count(*) from name_suggestions where page_id = pid) >= 200 then raise exception 'Çok fazla öneri var'; end if;
  insert into name_suggestions(page_id, name, from_name, note) values (pid, trim(p_name), trim(p_from), nullif(trim(p_note), ''));
end $$;

drop function if exists public.guest_product_suggest(text, text, text, text, text);
drop function if exists public.guest_product_suggest(text, text, text, text, text, text);
create function public.guest_product_suggest(p_slug text, p_name text, p_from text, p_link text, p_note text, p_pw text default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare pid uuid;
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 120
     or length(trim(coalesce(p_from, ''))) not between 1 and 80 then
    raise exception 'invalid';
  end if;
  pid := guest_page(p_slug, p_pw);
  if (select count(*) from product_suggestions where page_id = pid) >= 100 then raise exception 'Çok fazla öneri var'; end if;
  insert into product_suggestions(page_id, name, from_name, link, note)
  values (pid, trim(p_name), trim(p_from), case when p_link ~* '^https?://' then left(p_link, 500) end, left(p_note, 300));
end $$;

drop function if exists public.guest_guess(text, text, text, text, date, integer);
drop function if exists public.guest_guess(text, text, text, text, date, integer, text);
create function public.guest_guess(p_slug text, p_name text, p_gender text, p_gname text, p_date date, p_weight integer, p_pw text default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 80
     or (p_gender is not null and p_gender not in ('kiz', 'erkek'))
     or length(coalesce(p_gname, '')) > 60
     or (p_date is not null and p_date not between current_date - 60 and current_date + 300)
     or (p_weight is not null and p_weight not between 300 and 7000) then
    raise exception 'invalid';
  end if;
  insert into guesses(page_id, name, gender, guess_name, guess_date, guess_weight)
  values (guest_page(p_slug, p_pw), trim(p_name), p_gender, nullif(trim(p_gname), ''), p_date, p_weight);
end $$;

drop function if exists public.heart(bigint);
drop function if exists public.heart(bigint, text);
create function public.heart(uid bigint, p_pw text default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare s text;
begin
  select g.slug into s from updates u join pages g on g.id = u.page_id where u.id = uid;
  if s is null then raise exception 'not found'; end if;
  perform guest_page(s, p_pw);
  update updates set hearts = hearts + 1 where id = uid;
end $$;

-- 6) Fotoğraf deposu ---------------------------------------------------------------
-- Herkese açık bucket ama dosya adları tahmin edilemez (uuid) ve listeleme sadece sahibe açık.
-- Sadece JPEG/PNG/WebP, dosya başına en fazla 3 MB. SVG (betik çalıştırabilir) kabul edilmez.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Dosya yolunun ilk klasörü sayfa id'si olmalı; değilse null döner (geçersiz cast hatası olmaz).
create or replace function public.photo_page(p_name text)
 returns uuid
 language plpgsql
 immutable
as $$
declare s text := split_part(p_name, '/', 1);
begin
  if s ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return s::uuid; end if;
  return null;
end $$;

create or replace function public.photo_count(pid uuid)
 returns int
 language sql
 stable security definer
 set search_path to 'public'
as $$ select count(*)::int from storage.objects where bucket_id = 'photos' and public.photo_page(name) = pid $$;
revoke execute on function public.photo_count(uuid) from public, anon;
grant execute on function public.photo_count(uuid) to authenticated;

drop policy if exists ph_ins on storage.objects;
create policy ph_ins on storage.objects for insert to authenticated with check (
  bucket_id = 'photos'
  and name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$'
  and public.is_owner(public.photo_page(name))
  and public.photo_count(public.photo_page(name)) < 30);

drop policy if exists ph_sel on storage.objects;
create policy ph_sel on storage.objects for select to authenticated using (
  bucket_id = 'photos' and public.is_owner(public.photo_page(name)));

drop policy if exists ph_del on storage.objects;
create policy ph_del on storage.objects for delete to authenticated using (
  bucket_id = 'photos' and public.is_owner(public.photo_page(name)));
-- Güncelleme (üzerine yazma) politikası bilerek yok.

-- 7) İstatistik: fotoğraf ve şifre bilgisi eklendi (içerik yine yok).
drop function if exists public.stats_list_pages();
create function public.stats_list_pages()
 returns table(code text, created_on date, plan text, lang text, born boolean, has_pw boolean,
               products int, reservations int, contributions int, letters int,
               updates int, hearts int, name_suggestions int, product_suggestions int, guesses int, photos int)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $$
begin
  if not (is_admin() or is_stats_viewer()) then raise exception 'forbidden'; end if;
  return query
    select left(md5(g.id::text), 6), g.created_at::date, g.plan, g.lang, g.born, g.pw_hash is not null,
      (select count(*)::int from products p where p.page_id = g.id),
      (select count(*)::int from reservations r join products p on p.id = r.product_id where p.page_id = g.id and r.amount = 0),
      (select count(*)::int from reservations r join products p on p.id = r.product_id where p.page_id = g.id and r.amount > 0),
      (select count(*)::int from letters l where l.page_id = g.id),
      (select count(*)::int from updates u where u.page_id = g.id),
      (select coalesce(sum(u.hearts), 0)::int from updates u where u.page_id = g.id),
      (select count(*)::int from name_suggestions s where s.page_id = g.id),
      (select count(*)::int from product_suggestions s where s.page_id = g.id),
      (select count(*)::int from guesses s where s.page_id = g.id),
      (select count(*)::int from storage.objects o where o.bucket_id = 'photos' and public.photo_page(o.name) = g.id)
    from pages g
    order by g.created_at desc;
end $$;
revoke execute on function public.stats_list_pages() from public, anon;
grant execute on function public.stats_list_pages() to authenticated;

commit;
