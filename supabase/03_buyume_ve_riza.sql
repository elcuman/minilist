-- Minilist: yönlendirme (hangi sayfadan gelindi) ve KVKK açık rıza kaydı
-- ÖNCE 01 ve 02 çalıştırılmış olmalı. Yeni index.html yayına çıkmadan ÖNCE çalıştırın.
-- Tekrar çalıştırmak güvenlidir.

begin;

alter table public.pages add column if not exists ref text;          -- yeni ailenin geldiği sayfanın adresi
alter table public.pages add column if not exists consent_at timestamptz;  -- açık rızanın verildiği an
alter table public.pages drop constraint if exists pages_ref_len;
alter table public.pages add constraint pages_ref_len check (length(ref) <= 80);

-- Tetikleyici kullanıcı yetkisiyle çalışır ve RLS başka sayfaları gizler; bu yüzden kontrol burada yapılır.
create or replace function public.slug_exists(p_slug text)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $$ select exists (select 1 from pages where slug = p_slug) $$;
revoke execute on function public.slug_exists(text) from public, anon;
grant execute on function public.slug_exists(text) to authenticated;

-- ref ve consent_at sadece sayfa oluşturulurken yazılır; rıza zamanı sunucu saatidir.
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
      if new.consent_at is not null then new.consent_at := now(); end if;
      if new.ref is not null and not slug_exists(new.ref) then new.ref := null; end if;
    elsif new.id is distinct from old.id
       or new.owner is distinct from old.owner
       or new.slug is distinct from old.slug
       or new.plan is distinct from old.plan
       or new.plan_source is distinct from old.plan_source
       or new.created_at is distinct from old.created_at
       or new.pw_hash is distinct from old.pw_hash
       or new.ref is distinct from old.ref
       or new.consent_at is distinct from old.consent_at then
      raise exception 'Bu alan değiştirilemez';
    end if;
  end if;
  return new;
end $$;

-- get_page: ref (başka bir ailenin adresi) ve rıza zamanı misafire gönderilmez.
create or replace function public.get_page(p_slug text, p_pw text default null)
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
    return jsonb_build_object('locked', true, 'wrong', p_pw is not null,
      'lang', g.lang, 'theme', g.theme, 'palette', g.palette);
  end if;
  return jsonb_build_object(
    'page', (to_jsonb(g) - 'owner' - 'plan_source' - 'pw_hash' - 'ref' - 'consent_at') || jsonb_build_object('has_pw', g.pw_hash is not null),
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

-- İstatistik: her sayfanın getirdiği yeni aile sayısı (büyümenin ana ölçüsü). Adres yine gösterilmez.
drop function if exists public.stats_list_pages();
create function public.stats_list_pages()
 returns table(code text, created_on date, plan text, lang text, born boolean, has_pw boolean,
               products int, reservations int, contributions int, letters int,
               updates int, hearts int, name_suggestions int, product_suggestions int, guesses int, photos int, referred int)
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
      (select count(*)::int from storage.objects o where o.bucket_id = 'photos' and public.photo_page(o.name) = g.id),
      (select count(*)::int from pages x where x.ref = g.slug)
    from pages g
    order by g.created_at desc;
end $$;
revoke execute on function public.stats_list_pages() from public, anon;
grant execute on function public.stats_list_pages() to authenticated;

commit;
