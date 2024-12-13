do
$$
    declare
        _p regproc;
    begin
        begin
            _p := 'uuidv4'::regproc;
            -- Don't create if it is already defined
        exception
            when others then
                create function uuidv4() returns uuid
                    language internal as
                'gen_random_uuid';
        end;
        begin
            _p := 'uuidv7'::regproc;
            -- Don't create if it is already defined
        exception
            when others then
                create function uuidv7() returns uuid
                    language c as
                'MODULE_PATHNAME';
        end;
        begin
            _p := 'uuid_extract_version'::regproc;
            -- Don't create if it is already defined
        exception
            when others then
                create function uuid_extract_version() returns uuid
                    immutable
                    language c as
                'MODULE_PATHNAME';
        end;
        begin
            _p := 'uuidv7_interval'::regproc;
            -- Don't create if it is already defined
        exception
            when others then
                create function uuidv7_interval(shift interval) returns uuid
                    language c as
                'MODULE_PATHNAME';
        end;
        begin
            _p := 'uuid_extract_timestamp'::regproc;
            -- If it exists, let's test if it supports v7
            if uuid_extract_timestamp(uuidv7()) is null then
                raise exception 'outdated';
            end if;
        exception
            when others then
                create function uuid_extract_timestamp(uuid)
                    returns timestamptz
                    immutable
                    language c as
                'MODULE_PATHNAME';
        end;
    end;
$$;