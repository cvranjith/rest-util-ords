CREATE OR REPLACE PACKAGE "PKG_REST_UTILS"
is
procedure pr_process(p_msg in varchar2);
procedure put_resp(p_key in varchar2, p_val in varchar2);
function  getReqVal(p_tag in varchar2) return varchar2;
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
rec_array json_array_t;
function getParam(p_param_name in varchar2) return varchar2 result_cache
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
      dbg_file := utl_file.fopen(getParam('DEBUG_PATH'),nvl(r_id,'no-id')||'.txt','a',32767);
      utl_file.put_line(dbg_file,systimestamp||' ['||r_id||'] '||p_log);
    end;
  end if;
exception
  when others
  then
    dbg_mode := false;
end;
procedure raise_err(p_err in varchar2)
is
begin
  log('Error '||p_err);
  raise_application_error(-20001,p_err);
end;
function getReqVal(p_tag in varchar2) return varchar2
is
begin
  return tb_req(p_tag);
exception
  when no_data_found
  then
     return null;
end;
procedure parse(p_msg in clob)
is
 e1 json_element_t;
 o json_object_t;
 e json_element_t;
 keys json_key_list;
 key  varchar2(256);
begin
  log('Came to parse');
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
    raise_err('Only JSON Object is supported');
  end if;
end;
procedure put_resp(p_key in varchar2, p_val in varchar2)
is
begin
  tb_resp(tb_resp.count+1).key := p_key;
  tb_resp(tb_resp.count).val := p_val;
end;
procedure cleanup
is
begin
  tb_req.delete;
  tb_resp.delete;
  r_id :=null;
  rec_array := null;
end;
function getHandler(p_msg_code in varchar2) return iftm_rest_msg_handler%rowtype result_cache
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
procedure run_query(p_stmt in varchar2,p_resp_json_type in varchar2)
is
  l_desc_tab      dbms_sql.desc_tab;
  l_cols          number;
  l_cur           integer default dbms_sql.open_cursor;
  l_val           varchar2(4000);
  l_status        integer;
  l_tb_rec        ty_resp;
  o1              json_object_t;
  o               json_object_t;
begin
  dbms_sql.parse(  l_cur,  p_stmt, dbms_sql.native );
  dbms_sql.describe_columns( l_cur, l_cols, l_desc_tab );
  o1 := new json_object_t;
  rec_array := new json_array_t;
  if l_desc_tab.count > 0
  then
    for j in l_desc_tab.first .. l_desc_tab.last
    loop
      dbms_sql.define_column( l_cur, j, l_val, 4000 );
    end loop;
    l_status := dbms_sql.execute(l_cur);
    loop
      exit when (dbms_sql.fetch_rows(l_cur) <= 0);
      o := o1;
      for j in 1 .. l_desc_tab.count
      loop
        dbms_sql.column_value( l_cur, j, l_val );
        if p_resp_json_type = 'O'
        then
           put_resp(l_desc_tab(j).col_name,l_val);
        else
           o.put(l_desc_tab(j).col_name, l_val);
        end if;
      end loop;
      if p_resp_json_type = 'O'
      then
         exit;
      else
         rec_array.append(o);
      end if;
    end loop;
    dbms_sql.close_cursor(l_cur);
  end if;
end;
procedure run_proc(p_stmt in varchar2)
is
begin
  execute immediate 'begin '||p_stmt||' end;';
end;
procedure run_stmt(p_msg_code in varchar2)
is
  l_handler iftm_rest_msg_handler%rowtype;
  l_key varchar2(256);
begin
  log('in pr_run_stmt = '||p_msg_code);
  l_handler := getHandler(p_msg_code);
  put_resp('msgCode',l_handler.resp_msg_code);
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
    run_query(l_handler.stmt, l_handler.resp_json_type);
  else
    run_proc(l_handler.stmt);
  end if;
end;
function getResponse (p_resp_json_type in varchar2 := null) return varchar2
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
  if p_resp_json_type = 'A'
  then
    o.put('records',rec_array);
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
    cleanup();
    r_id := sys_guid();
    log('starting pr_process ...');
    log('Request = '||substr(p_msg,1,4000));
    r.req_ts := systimestamp;
    r.id := r_id;
    r.req := substr(p_msg,1,4000);
    put_resp('msgProducer',getParam('MSG_PRODUCER'));
    put_resp('logId',r_id);
    
    log('Going to Parse');
    parse(p_msg);
    log('Parse done');
    r.msg_code := tb_req('msgCode');
    r.msg_id := tb_req('msgId');
    put_resp('reqMsgCode',r.msg_code);
    put_resp('msgId',r.msg_id);
    log('Going Run Statement for msg code '||r.msg_code);
    run_stmt(r.msg_code);
    log('Done statement execution...');
    put_resp('status','success');
    l_resp := getResponse(getHandler(r.msg_code).resp_json_type);
    r.resp := substr(l_resp,1,4000);
    htp.p(l_resp);
    log('r.resp = '||r.resp);    
  exception
    when others
    then
      r.err := substr(sqlerrm||chr(10)||dbms_utility.format_error_backtrace,1,4000);
      log(r.err);
      put_resp('err',r.err);
      put_resp('status','error');
      l_resp := getResponse();
      r.resp := substr(l_resp,1,4000);
      htp.p(l_resp);
      rollback;
  end;
  r.resp_ts := systimestamp;
  insert into iftb_rest_msg_log values r;
  commit;
  cleanup();
  log('all done');
end;
begin
  dbg_mode := getParam('DEBUG_MODE') = 'Y';
end;
/



create or replace function req_val(p_tag in varchar2) return varchar2
is
begin
  return PKG_REST_UTILS.getReqVal(p_tag);
end;
/

create or replace procedure put_resp(p_key in varchar2, p_val in varchar2)
is
begin
  PKG_REST_UTILS.put_resp(p_key,p_val);
end;
/
