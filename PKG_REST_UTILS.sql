CREATE OR REPLACE PACKAGE "PKG_REST_UTILS"
is
procedure pr_process(p_msg in varchar2);
procedure pr_process(p_msg in blob);
procedure pr_resp_nvp(p_key in varchar2, p_val in varchar2);
function fn_req_val(p_tag in varchar2) return varchar2;
end;
/
CREATE OR REPLACE PACKAGE BODY "PKG_REST_UTILS"
is
type ty_tags is table of varchar2(4000) index by varchar2(256);
tb_req ty_tags;
r_id varchar2(100);
type rec_nvp is record (key varchar2(255),val varchar2(32767));
type ty_resp is table of rec_nvp index by binary_integer;
tb_resp ty_resp;
dbg_mode boolean :=false;
dbg_file utl_file.file_type;
function fn_rest_param(p_param_name in varchar2) return varchar2 result_cache
is
l_val iftm_rest_param.param_val%type;
begin
  select param_val
  into   l_val
  from   iftm_rest_param
  where  param_name = p_param_name;
  return l_val;
exception
  when no_data_found
  then
    return null;
end;
procedure log(p_log in varchar2)
is
begin
  if dbg_mode
  then
    begin
     utl_file.put_line(dbg_file,systimestamp||' ['||r_id||'] '||p_log);
    exception
    when utl_file.invalid_filehandle
    then
      dbg_file := utl_file.fopen(fn_rest_param('DEBUG_PATH'),nvl(r_id,'no-id')||'.txt','a',32767);
      utl_file.put_line(dbg_file,systimestamp||' ['||r_id||'] '||p_log);
    end;
  end if;
exception
  when others
  then
    dbg_mode := false;
end;
procedure pr_err(p_err in varchar2)
is
begin
  log('Error '||p_err);
  raise_application_error(-20001,p_err);
end;
function fn_req_val(p_tag in varchar2) return varchar2
is
begin
  return tb_req(p_tag);
exception
  when no_data_found
  then
     return null;
end;
procedure pr_parse(p_msg in clob)
is
 e1 json_element_t;
 o json_object_t;
 e json_element_t;
 keys json_key_list;
 key  varchar2(256);
begin
  e1 := json_element_t.parse(p_msg);
  if (e1.is_object) then
    o :=(treat (e1 as json_object_t));
    keys := o.get_keys;
    for i in 1 .. keys.count
    loop
      key := keys(i);
      e := o.get(key);
      tb_req(key) := rtrim(ltrim(e.to_string(),'"'),'"');
      log('key ' || key || ' has value ' || e.to_string);
    end loop;
  else
    pr_err('Only JSON Object is supported');
  end if;
end;
procedure pr_resp_nvp(p_key in varchar2, p_val in varchar2)
is
begin
  tb_resp(tb_resp.count+1).key := p_key;
  tb_resp(tb_resp.count).val := p_val;
end;
procedure pr_cleanup
is
begin
  tb_req.delete;
  tb_resp.delete;
  r_id :=null;
end;
function fn_get_handler(p_msg_code in varchar2) return iftm_rest_msg_handler%rowtype result_cache
is
  l_handler iftm_rest_msg_handler%rowtype;
begin
  log('Handler = '||p_msg_code);
  select *
  into	 l_handler
  from   iftm_rest_msg_handler
  where	 msg_code = p_msg_code;
  return l_handler;
end;
procedure pr_run_query(p_stmt in varchar2,p_resp_json_type in varchar2)
is
  l_desc_tab      dbms_sql.desc_tab;
  l_cols          number;
  l_cur           integer default dbms_sql.open_cursor;
  l_val           varchar2(4000);
  l_status        integer;
begin
  dbms_sql.parse(  l_cur,  p_stmt, dbms_sql.native );
  dbms_sql.describe_columns( l_cur, l_cols, l_desc_tab );
  if l_desc_tab.count > 0
  then
    for j in l_desc_tab.first .. l_desc_tab.last
    loop
      dbms_sql.define_column( l_cur, j, l_val, 4000 );
    end loop;
    l_status := dbms_sql.execute(l_cur);
    loop
      exit when (dbms_sql.fetch_rows(l_cur) <= 0);
      for j in 1 .. l_desc_tab.count
      loop
        dbms_sql.column_value( l_cur, j, l_val );
        pr_resp_nvp(l_desc_tab(j).col_name,l_val);
      end loop;
      if p_resp_json_type = 'O'
      then
         exit;
      end if;
    end loop;
    dbms_sql.close_cursor(l_cur);
  end if;
end;
procedure pr_run_proc(p_stmt in varchar2)
is
begin
  execute immediate 'begin '||p_stmt||' end;';
end;
procedure pr_run_stmt(p_msg_code in varchar2)
is
  l_handler iftm_rest_msg_handler%rowtype;
  l_key varchar2(256);
begin
  log('in pr_run_stmt = '||p_msg_code);
  l_handler := fn_get_handler(p_msg_code);
  pr_resp_nvp('msgCode',l_handler.resp_msg_code);
  log('sql stmt is = '||l_handler.stmt);
  execute immediate 'alter session set cursor_sharing=force';
  execute immediate 'alter session set nls_date_format=''YYYY-MM-DD:HH24:MI:SS''';
  l_key := tb_req.first;
  while l_key is not null
  loop
    l_handler.stmt := replace(l_handler.stmt,'$'||l_key||'$',tb_req(l_key));
    l_key := tb_req.next(l_key);
  end loop;
  log('sql stmt is = '||l_handler.stmt);
  if l_handler.query_or_proc = 'Q'
  then
    pr_run_query(l_handler.stmt, l_handler.resp_json_type);
  else
    pr_run_proc(l_handler.stmt);
  end if;
end;
function fn_response return varchar2
is
  o json_object_t;
begin
  o := new json_object_t;
  if tb_resp.count > 0
  then
    for i in tb_resp.first..tb_resp.last
    loop
      o.put(tb_resp(i).key, tb_resp(i).val);
    end loop;
  end if;
  return o.to_string();
end;
procedure pr_process(p_msg in varchar2)
is
  r iftb_rest_msg_log%rowtype;
  l_resp varchar2(32767);
begin
  begin
    owa_util.mime_header('application/json',true);
    pr_cleanup;
    r_id := sys_guid();
    log('starting pr_process ...');
    log('Request = '||substr(p_msg,1,4000));
    r.req_ts := systimestamp;
    r.id := r_id;
    r.req := substr(p_msg,1,4000);
    pr_resp_nvp('logId',r_id);
    log('Going to Parse');
    pr_parse(p_msg);
    log('Parse done');
    r.msg_code := tb_req('msgCode');
    r.msg_id := tb_req('msgId');
    pr_resp_nvp('reqMsgCode',r.msg_code);
    pr_resp_nvp('msgId',r.msg_id);
    log('Going Run Statement for msg code '||r.msg_code);
    pr_run_stmt(r.msg_code);
    log('Done statement execution...');
    pr_resp_nvp('status','success');
    l_resp := fn_response;
    r.resp := substr(l_resp,1,4000);
    htp.p(l_resp);
    log('r.resp = '||r.resp);    
  exception
    when others
    then
      r.err := substr(sqlerrm||chr(10)||dbms_utility.format_error_backtrace,1,4000);
      log(r.err);
      pr_resp_nvp('err',r.err);
      pr_resp_nvp('status','error');
      l_resp := fn_response;
      r.resp := substr(l_resp,1,4000);
      htp.p(l_resp);
      rollback;
  end;
  r.resp_ts := systimestamp;
  insert into iftb_rest_msg_log values r;
  commit;
  pr_cleanup;
  log('all done');
end;
procedure pr_process(p_msg in blob)
is
  l_clob         clob;
  l_dest_offset  pls_integer := 1;
  l_src_offset   pls_integer := 1;
  l_lang_context pls_integer := dbms_lob.default_lang_ctx;
  l_warning      pls_integer;
begin
  dbms_lob.createtemporary(lob_loc => l_clob,cache => false,dur=> dbms_lob.call);
  dbms_lob.converttoclob(dest_lob => l_clob, src_blob => p_msg,amount => dbms_lob.lobmaxsize,dest_offset => l_dest_offset,src_offset => l_src_offset, blob_csid => DBMS_LOB.default_csid, lang_context => l_lang_context, warning => l_warning);
  pr_process(l_clob);
  dbms_lob.freetemporary(lob_loc => l_clob);
end;
begin
  dbg_mode := fn_rest_param('DEBUG_MODE') = 'Y';
end;
/


create or replace function reqval(p_tag in varchar2) return varchar2
is
begin
  return PKG_REST_UTILS.fn_req_val(p_tag);
end;
/

create or replace procedure put_resp(p_key in varchar2, p_val in varchar2)
is
begin
  PKG_REST_UTILS.pr_resp_nvp(p_key,p_val);
end;
/

