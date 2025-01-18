create function assemble_schema(conn_info text, fs anyelement, path text default '')
    returns table
            (
                execution_position  int,
                migration_filename  text,
                migration_statement text,
                execution_error     text
            )
    language plpgsql
as
$$
declare
    rec                             record;
    remote_table_fs                 omni_vfs.table_fs;
    remote_table_fs_name            text    = 'omni_schema_migration_fs';
    current_filename                text;
    successful_statement_executions int     = 0;
    error_message                   text;
    error_detail text;
    try_again                       boolean = false;
    try_again                       boolean = true;
    failed_files                    text[] = {};  
    retry_count                     int = 0;     
    max_retries                     int = 3;      
begin
    -- statement execution status
    create temp table omni_schema_execution_status
    (
        id                       bigserial primary key,
        filepath                 text    not null,
        language                 text,
        extension                text,
        file_processor           text,
        file_processor_extension text,
        processor                text,
        processor_extension      text,
        code                     text    not null,
        -- order of successful execution
        execution_number         int,
        -- whether statement is executed successfully
        execution_successful     boolean not null default false,
        -- error for last execution of the statement
        last_execution_error     text
        -- Retry count to track attempts
        retry_count              int default 0
    ) on commit drop;

    <<top>>
    begin
        -- conn for setting up table_fs in remote database
        perform dblink_connect(remote_table_fs_name, conn_info);

        -- prepare necessary extensions in the remote database
        for rec in select distinct extension
                   from omni_schema.languages
                   union
                   select distinct file_processor_extension as extension
                   from omni_schema.languages
                   union
                   select distinct processor_extension as extension
                   from omni_schema.auxiliary_tools
            loop
                if exists (select from pg_extension where extname = rec.extension) then
                    perform dblink(remote_table_fs_name,
                                   format('create extension if not exists %s cascade', rec.extension));
                end if;
            end loop;

        perform dblink(remote_table_fs_name, 'create extension if not exists omni_vfs cascade');
        -- create table_fs in remote database
        select (f).id
        from dblink(remote_table_fs_name,
                    format('select omni_vfs.table_fs(%L)', remote_table_fs_name)) as t(f omni_vfs.table_fs)
        into remote_table_fs;

        -- read all files recognised by omni_schema.languages and omni_schema.auxiliary_tools
        for rec in
            select path || '/' || name                                           as name,
                   convert_from(omni_vfs.read(fs, path || '/' || name), 'UTF-8') as code,
                   language,
                   extension,
                   file_processor,
                   file_processor_extension,
                   processor,
                   processor_extension
            from omni_vfs.list_recursively(fs, path) files
                     left join omni_schema.languages on files.name like concat('%', languages.file_extension)
                     left join omni_schema.auxiliary_tools
                               on files.name like concat(coalesce(auxiliary_tools.filename_stem, '%'), '.',
                                                         auxiliary_tools.filename_extension)
            where (auxiliary_tools.id is not null or
                   languages.id is not null)
              and kind = 'file'
            order by coalesce(auxiliary_tools.priority, languages.priority) desc, name
            loop
                -- create table_fs entry for the file along with it's data
                perform dblink(remote_table_fs_name,
                               format(
                                       'insert into omni_vfs.table_fs_files(filesystem_id, filename, kind) values (%s, %L, ''file'')',
                                       remote_table_fs.id, rec.name));
                perform dblink(remote_table_fs_name,
                               format(
                                       'insert into omni_vfs.table_fs_file_data (file_id, data) values
                                          (
                                            omni_vfs.table_fs_file_id(omni_vfs.table_fs(%L), %L),
                                            %L
                                          )',
                                       remote_table_fs_name, rec.name, convert_to(rec.code, 'utf-8')));

                if rec.code ~ 'omni_schema\[\[ignore\]\]' then
                    -- Ignore the file
                    continue;
                end if;
                if rec.language = 'sql' then
                    -- process sql language files statement by statement
                    declare
                        code text := convert_from(omni_vfs.read(fs, rec.name), 'UTF-8');
                        code_rec record;
                    begin
                        for code_rec in select source as current_statement, line, col
                                                 from
                                                     omni_sql.raw_statements(code::cstring)
                            loop
                                raise notice '%', json_build_object('type', 'info', 'message', 'Executing', 'code',
                                                                    code_rec.current_statement,
                                                                    'file', rec.name, 'line', code_rec.line, 'col',
                                                                    code_rec.col);
                                insert
                                into omni_schema_execution_status(filepath, language, code)
                                values (rec.name, rec.language, code_rec.current_statement);
                            end loop;
                    exception
                        when syntax_error then
                            raise notice '%', json_build_object('type', 'error', 'message', sqlerrm,
                                                                'file', rec.name);
                            insert
                            into omni_schema_execution_status(filepath, language, code, last_execution_error)
                            values (rec.name, rec.language, code, sqlerrm);

                            exit top;
                    end;
                else
                    -- process the whole file at once for other languages
                    insert
                    into omni_schema_execution_status(filepath, language, extension, file_processor,
                                                      file_processor_extension, processor, processor_extension, code)
                    values (rec.name, rec.language, rec.extension, rec.file_processor, rec.file_processor_extension,
                            rec.processor, rec.processor_extension, rec.code);
                end if;
            end loop;
        for rec in
            select distinct filepath from omni_schema_execution_status
            loop
                /*
                    create separate connections for each file to restrict any 'SET' statement
                    effects to the file which contains it
                */
                perform dblink_connect(rec.filepath, conn_info);
            end loop;
         -- Retry logic implementation
        while try_again loop
        -- Process all files in the execution status table, retrying failed ones first
           for current_filename in
            select filepath from omni_schema_execution_status
            where execution_successful = false
            order by coalesce(omni_schema.languages.priority, omni_schema.auxiliary_tools.priority) desc, id
           loop
            -- Attempt execution of file statements
            for rec in
                select * from omni_schema_execution_status
                where filepath = current_filename and execution_successful = false
            loop
                begin
                    -- Execute statement
                    perform execute_statement(rec);  -- Replace this with your execution logic

                    -- If execution is successful, update status and reset retry count
                    update omni_schema_execution_status
                    set execution_successful = true, retry_count = 0
                    where id = rec.id;

                exception
                    when others then
                        -- Increment retry count for failed file
                        update omni_schema_execution_status
                        set retry_count = retry_count + 1
                        where id = rec.id;

                        -- If retry count is less than max retries, add file to retry queue
                        if retry_count < max_retries then
                            failed_files := array_append(failed_files, rec.filepath);
                        else
                            -- After max retries, mark as permanently failed
                            update omni_schema_execution_status
                            set last_execution_error = 'Max retries reached'
                            where id = rec.id;
                        end if;
                end;
            end loop;
        end loop;

            -- If there are failed files to retry, retry them
              if array_length(failed_files, 1) > 0 then
              -- Sort and retry failed files respecting priority
               failed_files := array_sort(failed_files);  -- Sort based on priority
               try_again := true;
              else
               try_again := false;  -- No more retries left
             end if;
            end loop;
   
        -- execute until all statements are successfully executed or no more executions are successful
        while true
            loop
                <<file>>
                for current_filename in select distinct filepath from omni_schema_execution_status order by filepath
                    loop
                        <<statement>>
                        for rec in select *
                                   from omni_schema_execution_status
                                   where execution_successful = false
                                     and filepath = current_filename
                                   order by id
                            loop
                                declare
                                    _filepath text;
                                    _code     text;
                                begin
                                    if rec.language is null and rec.processor is not null then
                                        if not exists(select *
                                                      from dblink(rec.filepath,
                                                                  format(
                                                                          'select true from pg_extension where extname = %L',
                                                                          rec.processor_extension)) as t(b boolean)) then
                                            raise exception 'Extension % required for auxiliary tool (required for %) is not installed', rec.processor_extension, rec.filepath;
                                        else
                                            perform *
                                            from dblink(rec.filepath,
                                                        format('with cte as (%s) select true from cte',
                                                               format('select %s(%L::text)', rec.processor, rec.code))) as t(b boolean);
                                        end if;
                                    elsif rec.language = 'sql' then
                                        -- normalize sql statement like removing whitespace
                                        rec.code = omni_sql.statement_in(rec.code::cstring);
                                        if omni_sql.statement_type(rec.code::omni_sql.statement) = 'SelectStmt' then
                                            /*
                                                SELECT statement result set can be of any shape(number of columns, their types)
                                                so wrap select statements in cte to give it consistent shape and avoid the
                                                ERROR:  function returning record called in context that cannot accept type record
                                            */
                                            perform *
                                            from dblink(rec.filepath,
                                                        format('with cte as (%s) select true from cte', rec.code)) as t(b boolean);
                                        else
                                            perform dblink(rec.filepath, rec.code);
                                        end if;
                                    else
                                        if not exists(select *
                                                      from dblink(rec.filepath,
                                                                  format(
                                                                          'select true from pg_extension where extname = %L',
                                                                          rec.extension)) as t(b boolean)) then
                                            raise exception 'Extension % required for language % (required for %) is not installed', rec.extension, rec.language, rec.filepath;
                                        else
                                            -- Prepare and execute the SQL create function construct
                                            if rec.file_processor is not null then
                                                if (rec.file_processor_extension is not null and
                                                    exists(select *
                                                           from dblink(rec.filepath,
                                                                       format(
                                                                               'select true from pg_extension where extname = %L',
                                                                               rec.file_processor_extension)) as t(b boolean))) or
                                                   rec.file_processor_extension is null then
                                                    -- Can use the file processor
                                                    perform *
                                                    from dblink(rec.filepath, format(
                                                            'with cte as (select %s(%L::text, filename => %L::text, replace => true, fs => %L::%s)) select true from cte',
                                                            rec.file_processor,
                                                            rec.code, rec.filepath, remote_table_fs::text,
                                                            pg_typeof(remote_table_fs))) as t(b boolean);
                                                end if;
                                            end if;
                                            if rec.code ~ 'SQL\[\[.*\]\]' then
                                                perform dblink(rec.filepath, format('%s language %I as %L',
                                                                                    substring(rec.code from 'SQL\[\[(.*?)\]\]'),
                                                                                    rec.language,
                                                                                    rec.code));
                                            end if;
                                        end if;
                                    end if;
                                    -- update statement execution status
                                    successful_statement_executions = successful_statement_executions + 1;
                                    update omni_schema_execution_status
                                    set execution_number     = successful_statement_executions,
                                        execution_successful = true,
                                        last_execution_error = null
                                    where id = rec.id
                                    returning filepath, code into _filepath, _code;
                                    raise notice '%', json_build_object('type', 'info', 'message',
                                                                        'Completed', 'code', _code,
                                                                        'file', _filepath);
                                    -- at least one succeeded, worth trying again
                                    try_again = true;
                                exception
                                    when others then
                                        get stacked diagnostics error_message = message_text, error_detail = pg_exception_detail;
                                        update omni_schema_execution_status
                                        set last_execution_error = error_message
                                        where id = rec.id
                                        returning filepath, code into _filepath, _code;
                                        raise notice '%', json_build_object('type', 'error', 'message',
                                                                            sqlerrm, 'detail', error_detail, 'code',
                                                                            _code,
                                                                            'file', _filepath);
                                        -- go to next file if statement execution fails to preserve serial execution of statements in a file
                                        continue file;
                                end;
                            end loop statement;
                    end loop file;
                if try_again = true then
                    try_again = false;
                else
                    exit;
                end if;
            end loop;

        for rec in
            select distinct filepath from omni_schema_execution_status
            loop
                perform dblink_disconnect(rec.filepath);
            end loop;
    end;
    -- close the connections set up at the beginning
    perform dblink_disconnect(remote_table_fs_name);

    return query select execution_number,
                        filepath,
                        code,
                        last_execution_error
                 from omni_schema_execution_status
                 order by execution_number;
end;
$$;