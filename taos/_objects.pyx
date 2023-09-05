# cython: profile=True

from libc.stdlib cimport malloc, free
import asyncio
from typing import Optional, List
from taos._cinterface cimport *
from taos._parser cimport _parse_string, _parse_timestamp, _parse_binary_string, _parse_nchar_string
from taos._cinterface import SIZED_TYPE, UNSIZED_TYPE, CONVERT_FUNC
import datetime as dt
import pytz
from collections import namedtuple
from taos.error import ProgrammingError, OperationalError, ConnectionError, DatabaseError, StatementError, InternalError, TmqError, SchemalessError
from taos.constants import FieldType

_priv_tz = None
_utc_tz = pytz.timezone("UTC")
try:
    _datetime_epoch = dt.datetime.fromtimestamp(0)
except OSError:
    _datetime_epoch = dt.datetime.fromtimestamp(86400) - dt.timedelta(seconds=86400)
_utc_datetime_epoch = _utc_tz.localize(dt.datetime.utcfromtimestamp(0))
_priv_datetime_epoch = None


def set_tz(tz):
    global _priv_tz, _priv_datetime_epoch
    _priv_tz = tz
    _priv_datetime_epoch = _utc_datetime_epoch.astimezone(_priv_tz)


cdef void async_result_future_wrapper(void *param, TAOS_RES *res, int code) nogil:
    with gil:
        fut = <object>param
        if code != 0:
            e = ProgrammingError(taos_errstr(res), code)
            fut.get_loop().call_soon_threadsafe(fut.set_exception, e)
        else:
            taos_result = TaosResult(<size_t>res)
            fut.get_loop().call_soon_threadsafe(fut.set_result, taos_result)


cdef void async_rows_future_wrapper(void *param, TAOS_RES *res, int num_of_rows) nogil:
    cdef int i = 0
    with gil:
        taos_result, fut = <tuple>param
        rows = []
        if num_of_rows > 0:
            for row in taos_result.rows_iter():
                rows.append(row)
                i += 1
                if i >= num_of_rows:
                    break

        fut.get_loop().call_soon_threadsafe(fut.set_result, rows)


cdef void async_block_future_wrapper(void *param, TAOS_RES *res, int num_of_rows) nogil:
    cdef int i = 0
    with gil:
        taos_result, fut = <tuple>param
        block, n = [], 0
        if num_of_rows > 0:
            block, n = taos_result.fetch_block()

        fut.get_loop().call_soon_threadsafe(fut.set_result, (block, n))


cdef class TaosConnection:
    cdef char *_host
    cdef char *_user
    cdef char *_password
    cdef char *_database
    cdef uint16_t _port
    cdef char *_tz
    cdef char *_config
    cdef TAOS *_raw_conn

    def __cinit__(self, host=None, user="root", password="taosdata", database=None, port=None, timezone=None, config=None):
        if host:
            host = host.encode("utf-8")
            self._host = host

        if user:
            user = user.encode("utf-8")
            self._user = user

        if password:
            password = password.encode("utf-8")
            self._password = password

        if database:
            database =database.encode("utf-8")
            self._database = database

        if port:
            self._port = port or 0

        if timezone:
            timezone = timezone.encode("utf-8")
            self._tz = timezone

        if config:
            config = config.encode("utf-8")
            self._config = config

        self._init_options()
        self._init_conn()
        self._check_conn_error()

    def _init_options(self):
        if self._tz:
            set_tz(pytz.timezone(self._tz.decode("utf-8")))
            taos_options(TSDB_OPTION.TSDB_OPTION_TIMEZONE, self._tz)

        if self._config:
            taos_options(TSDB_OPTION.TSDB_OPTION_CONFIGDIR, self._config)

    def _init_conn(self):
        self._raw_conn = taos_connect(self._host, self._user, self._password, self._database, self._port)

    def _check_conn_error(self):
        errno = taos_errno(self._raw_conn)
        if errno != 0:
            errstr = taos_errstr(self._raw_conn)
            raise ConnectionError(errstr, errno)

    def __dealloc__(self):
        self.close()

    @property
    def client_info(self):
        return taos_get_client_info().decode("utf-8")

    @property
    def server_info(self):
        # type: () -> str
        if self._raw_conn is NULL:
            return
        return taos_get_server_info(self._raw_conn).decode("utf-8")

    def select_db(self, database: str):
        _database = database.encode("utf-8")
        res = taos_select_db(self._raw_conn, _database)
        if res != 0:
            raise DatabaseError("select database error", res)

    def execute(self, sql: str, req_id: Optional[int] = None):
        return self.query(sql, req_id).affected_rows

    def query(self, sql: str, req_id: Optional[int] = None):
        _sql = sql.encode("utf-8")
        if req_id is None:
            res = taos_query(self._raw_conn, _sql)
        else:
            res = taos_query_with_reqid(self._raw_conn, _sql, req_id)

        errno = taos_errno(res)
        if errno != 0:
            errstr = taos_errstr(res)
            taos_free_result(res)
            raise ProgrammingError(errstr, errno)

        return TaosResult(<size_t>res)

    async def query_async(self, sql: str, req_id: Optional[int] = None):
        loop = asyncio.get_event_loop()
        _sql = sql.encode("utf-8")
        fut = loop.create_future()
        if req_id is None:
            taos_query_a(self._raw_conn, _sql, async_result_future_wrapper, <void*>fut)
        else:
            taos_query_a_with_reqid(self._raw_conn, _sql, async_result_future_wrapper, <void*>fut, req_id)

        res = await fut
        return res

    def statement(self, sql: Optional[str]=None):
        if self._raw_conn is NULL:
            return None

        stmt = taos_stmt_init(self._raw_conn)
        if stmt is NULL:
            raise StatementError("init taos statement failed!")

        if sql:
            _sql = sql.encode("utf-8")
            code = taos_stmt_prepare(stmt, _sql, len(_sql))
            if code != 0:
                stmt_errstr = taos_stmt_errstr(stmt).decode("utf-8")
                raise StatementError(stmt_errstr, code)

        return TaosStmt(<size_t>stmt)
        

    def load_table_info(self, tables: list):
        _tables = ",".join(tables).encode("utf-8")
        taos_load_table_info(self._raw_conn, _tables)

    def close(self):
        if self._raw_conn is not NULL:
            taos_close(self._raw_conn)
            self._raw_conn = NULL

    def schemaless_insert(
            self,
            lines: List[str],
            protocol: TSDB_SML_PROTOCOL_TYPE,
            precision: TSDB_SML_TIMESTAMP_TYPE,
            req_id: Optional[int] = None,
            ttl: Optional[int] = None,
    ) -> int:
        """
        1.Line protocol and schemaless support

        ## Example

        ```python
        import taos
        conn = taos.connect()
        conn.exec("drop database if exists test")
        conn.select_db("test")
        lines = [
            'ste,t2=5,t3=L"ste" c1=true,c2=4,c3="string" 1626056811855516532',
        ]
        conn.schemaless_insert(lines, 0, "ns")
        ```

        2.OpenTSDB telnet style API format support

        ## Example

        ```python
        import taos
        conn = taos.connect()
        conn.exec("drop database if exists test")
        conn.select_db("test")
        lines = [
            'cpu_load 1626056811855516532ns 2.0f32 id="tb1",host="host0",interface="eth0"',
        ]
        conn.schemaless_insert(lines, 1, None)
        ```

        3.OpenTSDB HTTP JSON format support

        ## Example

        ```python
        import taos
        conn = taos.connect()
        conn.exec("drop database if exists test")
        conn.select_db("test")
        payload = ['''
        {
            "metric": "cpu_load_0",
            "timestamp": 1626006833610123,
            "value": 55.5,
            "tags":
                {
                    "host": "ubuntu",
                    "interface": "eth0",
                    "Id": "tb0"
                }
        }
        ''']
        conn.schemaless_insert(lines, 2, None)
        ```
        """
        num_of_lines = len(lines)
        _lines = <char**>malloc(num_of_lines * sizeof(char*))
        if _lines is NULL:
            raise MemoryError()

        for i in range(num_of_lines):
            _line = lines[i].encode("utf-8")
            _lines[i] = _line

        if ttl is None:
            if req_id is None:
                res = taos_schemaless_insert(
                    self._raw_conn,
                    _lines,
                    num_of_lines,
                    protocol,
                    precision,
                )
            else:
                res = taos_schemaless_insert_with_reqid(
                    self._raw_conn,
                    _lines,
                    num_of_lines,
                    protocol,
                    precision,
                    req_id,
                )
        else:
            if req_id is None:
                res = taos_schemaless_insert_ttl(
                    self._raw_conn,
                    _lines,
                    num_of_lines,
                    protocol,
                    precision,
                    ttl,
                )
            else:
                res = taos_schemaless_insert_ttl_with_reqid(
                    self._raw_conn,
                    _lines,
                    num_of_lines,
                    protocol,
                    precision,
                    ttl,
                    req_id,
                )
        
        free(_lines)
        errno = taos_errno(res)
        affected_rows = taos_affected_rows(res)
        if errno != 0:
            errstr = taos_errstr(res)
            taos_free_result(res)
            raise SchemalessError(errstr, errno, affected_rows)

        return TaosResult(<size_t>res)

    def schemaless_insert_raw(
            self,
            lines: str,
            protocol: TSDB_SML_PROTOCOL_TYPE,
            precision: TSDB_SML_TIMESTAMP_TYPE,
            req_id: Optional[int] = None,
            ttl: Optional[int] = None,
    ) -> int:
        """
        1.Line protocol and schemaless support

        ## Example

        ```python
        import taos
        conn = taos.connect()
        conn.exec("drop database if exists test")
        conn.select_db("test")
        lines = 'ste,t2=5,t3=L"ste" c1=true,c2=4,c3="string" 1626056811855516532'
        conn.schemaless_insert_raw(lines, 0, "ns")
        ```

        2.OpenTSDB telnet style API format support

        ## Example

        ```python
        import taos
        conn = taos.connect()
        conn.exec("drop database if exists test")
        conn.select_db("test")
        lines = 'cpu_load 1626056811855516532ns 2.0f32 id="tb1",host="host0",interface="eth0"'
        conn.schemaless_insert_raw(lines, 1, None)
        ```

        3.OpenTSDB HTTP JSON format support

        ## Example

        ```python
        import taos
        conn = taos.connect()
        conn.exec("drop database if exists test")
        conn.select_db("test")
        payload = '''
        {
            "metric": "cpu_load_0",
            "timestamp": 1626006833610123,
            "value": 55.5,
            "tags":
                {
                    "host": "ubuntu",
                    "interface": "eth0",
                    "Id": "tb0"
                }
        }
        '''
        conn.schemaless_insert_raw(lines, 2, None)
        ```
        """
        cdef int32_t total_rows
        _lines = lines.encode("utf-8")
        _length = len(_lines)

        if ttl is None:
            if req_id is None:
                res = taos_schemaless_insert_raw(
                    self._raw_conn,
                    _lines,
                    _length,
                    &total_rows,
                    protocol,
                    precision,
                )
            else:
                res = taos_schemaless_insert_raw_with_reqid(
                    self._raw_conn,
                    _lines,
                    _length,
                    &total_rows,
                    protocol,
                    precision,
                    req_id,
                )
        else:
            if req_id is None:
                res = taos_schemaless_insert_raw_ttl(
                    self._raw_conn,
                    _lines,
                    _length,
                    &total_rows,
                    protocol,
                    precision,
                    ttl,
                )
            else:
                res = taos_schemaless_insert_raw_ttl_with_reqid(
                    self._raw_conn,
                    _lines,
                    _length,
                    &total_rows,
                    protocol,
                    precision,
                    ttl,
                    req_id,
                )

        errno = taos_errno(res)
        affected_rows = taos_affected_rows(res)
        if errno != 0:
            errstr = taos_errstr(res)
            taos_free_result(res)
            raise SchemalessError(errstr, errno, affected_rows)
        
        return TaosResult(<size_t>res)

    def commit(self):
        """Commit any pending transaction to the database.

        Since TDengine do not support transactions, the implement is void functionality.
        """
        pass

    def rollback(self):
        """Void functionality"""
        pass

    def cursor(self):
        return TaosCursor(self)

    def clear_result_set(self):
        """Clear unused result set on this connection."""
        pass

    def get_table_vgroup_id(self, db: str, table: str):
        # type: (str, str) -> int
        """
        get table's vgroup id. It's require db name and table name, and return an int type vgroup id.
        """
        cdef int vg_id
        _db = db.encode("utf-8")
        _table = table.encode("utf-8")
        code = taos_get_table_vgId(self._raw_conn, _db, _table, &vg_id)
        if code != 0:
            raise InternalError(taos_errstr(NULL))
        return vg_id


cdef class TaosField:
    cdef str _name
    cdef int8_t _type
    cdef int32_t _bytes

    def __cinit__(self, str name, int8_t type_, int32_t bytes):
        self._name = name
        self._type = type_
        self._bytes = bytes

    @property
    def name(self):
        return self._name

    @property
    def type(self):
        return self._type

    @property
    def bytes(self):
        return self._bytes

    @property
    def length(self):
        return self._bytes

    def __str__(self):
        return "TaosField{name: %s, type: %d, bytes: %d}" % (self.name, self.type, self.bytes)

    def __repr__(self):
        return "TaosField{name: %s, type: %d, bytes: %d}" % (self.name, self.type, self.bytes)

    def __getitem__(self, item):
        return getattr(self, item)


cdef class TaosResult:
    cdef TAOS_RES *_res
    cdef TAOS_FIELD *_fields
    cdef int _field_count
    cdef int _precision
    cdef int _row_count
    cdef int _affected_rows

    def __cinit__(self, size_t res):
        self._res = <TAOS_RES*>res
        self._check_result_error()
        self._field_count = taos_field_count(self._res)
        self._fields = taos_fetch_fields(self._res)
        self._precision = taos_result_precision(self._res)
        self._affected_rows = taos_affected_rows(self._res)
        self._row_count = 0

    def __str__(self):
        return "TaosResult{res: %s}" % (<size_t>self._res, )

    def __repr__(self):
        return "TaosResult{res: %s}" % (<size_t>self._res, )

    def __iter__(self):
        return self.rows_iter()

    @property
    def fields(self):
        return [TaosField(f.name.decode("utf-8"), f.type, f.bytes) for f in self._fields[:self._field_count]]

    @property
    def field_count(self):
        return self._field_count

    @property
    def precision(self):
        return self._precision

    @property
    def affected_rows(self):
        return self._affected_rows

    @property
    def row_count(self):
        return self._row_count

    def _check_result_error(self):
        errno =  taos_errno(self._res)
        if errno != 0:
            errstr = taos_errstr(self._res)
            raise ProgrammingError(errstr, errno)

    def _fetch_block(self):
        cdef TAOS_ROW pblock
        num_of_rows = taos_fetch_block(self._res, &pblock)
        if num_of_rows == 0:
            return [], 0

        blocks = [None] * self._field_count
        dt_epoch = _priv_datetime_epoch if _priv_datetime_epoch else _datetime_epoch
        cdef int i
        for i in range(self._field_count):
            data = pblock[i]
            field = self._fields[i]

            if field.type in UNSIZED_TYPE:
                offsets = taos_get_column_data_offset(self._res, i)
                blocks[i] = _parse_string(<size_t>data, num_of_rows, offsets)
            elif field.type in SIZED_TYPE:
                is_null = taos_get_column_data_is_null(self._res, i, num_of_rows)
                blocks[i] = CONVERT_FUNC[field.type](<size_t>data, num_of_rows, is_null)
            elif field.type in (TSDB_DATA_TYPE_TIMESTAMP, ):
                is_null = taos_get_column_data_is_null(self._res, i, num_of_rows)
                blocks[i] = _parse_timestamp(<size_t>data, num_of_rows, is_null, self._precision, dt_epoch)
            else:
                pass

        return blocks, abs(num_of_rows)

    def fetch_block(self):
        if self._res is NULL:
            raise OperationalError("Invalid use of fetch iterator")

        block, num_of_rows = self._fetch_block()
        self._row_count += num_of_rows

        return [r for r in map(tuple, zip(*block))], num_of_rows

    def fetch_all(self):
        if self._res is NULL:
            raise OperationalError("Invalid use of fetchall")

        blocks = []
        while True:
            block, num_of_rows = self._fetch_block()
            self._check_result_error()

            if num_of_rows == 0:
                break

            self._row_count += num_of_rows
            blocks.append(block)

        return [r for b in blocks for r in map(tuple, zip(*b))]

    def fetch_all_into_dict(self):
        if self._res is NULL:
            raise OperationalError("Invalid use of fetchall")

        field_names = [field.name for field in self.fields]
        dict_row_cls = namedtuple('DictRow', field_names)
        blocks = []
        while True:
            block, num_of_rows = self._fetch_block()
            self._check_result_error()

            if num_of_rows == 0:
                break

            self._row_count += num_of_rows
            blocks.append(block)

        return [dict_row_cls(*r)._asdict() for b in blocks for r in map(tuple, zip(*b))]

    def rows_iter(self):
        if self._res is NULL:
            raise OperationalError("Invalid use of rows_iter")

        cdef TAOS_ROW taos_row
        cdef int i
        cdef int[1] offsets = [-2]
        dt_epoch = _priv_datetime_epoch if _priv_datetime_epoch else _datetime_epoch
        is_null = [False]

        while True:
            taos_row = taos_fetch_row(self._res)
            if taos_row is NULL:
                break

            row = [None] * self._field_count
            for i in range(self._field_count):
                data = taos_row[i]
                field = self._fields[i]
                if field.type in UNSIZED_TYPE:
                    row[i] = _parse_string(<size_t>data, 1, offsets)[0]
                elif field.type in SIZED_TYPE:
                    row[i] = CONVERT_FUNC[field.type](<size_t>data, 1, is_null)[0]
                elif field.type in (TSDB_DATA_TYPE_TIMESTAMP, ):
                    row[i] = _parse_timestamp(<size_t>data, 1, is_null, self._precision, dt_epoch)[0]
                else:
                    pass

            self._row_count += 1
            yield row

    def blocks_iter(self):
        if self._res is NULL:
            raise OperationalError("Invalid use of rows_iter")

        while True:
            block, num_of_rows = self._fetch_block()

            if num_of_rows == 0:
                break

            yield [r for r in map(tuple, zip(*block))], num_of_rows

    async def rows_iter_a(self):
        if self._res is NULL:
            raise OperationalError("Invalid use of rows_iter_a")

        loop = asyncio.get_event_loop()
        while True:
            fut = loop.create_future()
            param = (self, fut)
            taos_fetch_rows_a(self._res, async_rows_future_wrapper, <void*>param)

            rows = await fut
            if not rows:
                break
            
            for row in rows:
                yield row

    async def blocks_iter_a(self):
        if self._res is NULL:
            raise OperationalError("Invalid use of blocks_iter_a")

        loop = asyncio.get_event_loop()
        while True:
            fut = loop.create_future()
            param = (self, fut)
            taos_fetch_rows_a(self._res, async_block_future_wrapper, <void*>param)
            # taos_fetch_raw_block_a(self._res, async_block_future_wrapper, <void*>param)

            block, n = await fut
            if not block:
                break
            
            yield block, n

    def __dealloc__(self):
        if self._res is not NULL:
            taos_free_result(self._res)

        self._res = NULL
        self._fields = NULL


cdef class TaosCursor:
    cdef list _description
    cdef TaosConnection _connection
    cdef TaosResult _result

    def __init__(self, connection: TaosConnection=None) -> None:
        self._description = []
        self._connection = connection
        self._result = None

    def __iter__(self):
        for block, _ in self._result.blocks_iter():
            for row in block:
                yield row

    def next(self):
        return next(self)

    @property
    def description(self):
        return self._description

    @property
    def rowcount(self):
        return self._result.row_count

    @property
    def affected_rows(self):
        """Return the rowcount of insertion"""
        return self._result.affected_rows

    def callproc(self, procname, *args):
        """Call a stored database procedure with the given name.

        Void functionality since no stored procedures.
        """
        pass

    def close(self):
        if self._connection is None:
            return False

        self._reset_result()
        self._connection = None

        return True

    def execute(self, operation, params=None, req_id: Optional[int] = None):
        """Prepare and execute a database operation (query or command)."""
        if not operation:
            return

        if not self._connection:
            raise ProgrammingError("Cursor is not connected")

        self._reset_result()
        sql = operation
        self._result = self._connection.query(sql, req_id)
        self._description = [(f.name, f.type, None, None, None, None, False) for f in self._result.fields]

        if self._result.field_count == 0:
            return self.affected_rows
        else:
            return self._result

    def execute_many(self, operation, data_list, req_id: Optional[int] = None):
        """
        Prepare a database operation (query or command) and then execute it against all parameter sequences or mappings
        found in the sequence seq_of_parameters.
        """
        sql = operation
        flag = True
        affected_rows = 0
        for line in data_list:
            if isinstance(line, dict):
                flag = False
                affected_rows += self.execute(sql.format(**line), req_id=req_id)
            elif isinstance(line, list):
                sql += f' {tuple(line)} '
            elif isinstance(line, tuple):
                sql += f' {line} '
        if flag:
            affected_rows += self.execute(sql, req_id=req_id)
        return affected_rows

    def fetchone(self):
        try:
            row = next(self)
        except StopIteration:
            row = None
        return row

    def fetchmany(self, size=None):
        size = size or 1
        rows = []
        for row in self:
            rows.append(row)
        
        return rows

    def fetchall(self):
        return [r for r in self]

    def nextset(self):
        pass

    def setinputsize(self, sizes):
        pass

    def setutputsize(self, size, column=None):
        pass

    def _reset_result(self):
        """Reset the result to unused version."""
        self._description = []
        self._result = None

    def __del__(self):
        self.close()


# ---------------------------------------- TMQ --------------------------------------------------------------- v
cdef void async_commit_future_wrapper(tmq_t *tmq, int32_t code, void *param) nogil:
    with gil:
        fut = <object>param
        fut.get_loop().call_soon_threadsafe(fut.set_result, code)


cdef class TopicPartition:
    cdef char *_topic
    cdef int32_t _partition
    cdef int64_t _offset
    cdef int64_t _begin
    cdef int64_t _end

    def __cinit__(self, str topic, int32_t partition, int64_t offset, int64_t begin=0, int64_t end=0):
        _topic = topic.encode("utf-8")
        self._topic = _topic
        self._partition = partition
        self._offset = offset
        self._begin = begin
        self._end = end

    @property
    def topic(self):
        return self._topic.decode("utf-8")

    @property
    def partition(self):
        return self._partition

    @property
    def offset(self):
        return self._offset

    @property
    def begin(self):
        return self._begin

    @property
    def end(self):
        return self._end


cdef class MessageBlock:
    cdef list _block
    cdef list _fields
    cdef int _nrows
    cdef int _ncols
    cdef str _table

    def __init__(self, block=None, fields=None, nrows=0, ncols=0, table=""):
        self._block = block or []
        self._fields = fields or []
        self._nrows = nrows
        self._ncols = ncols
        self._table = table

    def fields(self):
        return self._fields

    def nrows(self):
        return self._nrows

    def ncols(self):
        return self._ncols

    def table(self):
        return self._table

    def fetchall(self):
        return [r for r in self]

    def __iter__(self):
        return zip(*self._block)


cdef class Message:
    cdef TAOS_RES *_res
    cdef int _err_no
    cdef char *_err_str

    def __cinit__(self, size_t res):
        self._res = <TAOS_RES*>res
        self._err_no = taos_errno(self._res)
        self._err_str = taos_errstr(self._res)

    def error(self):
        return TmqError(self._err_str) if self._err_no else None

    def topic(self):
        return tmq_get_topic_name(self._res)

    def database(self):
        return tmq_get_db_name(self._res)

    def vgroup(self):
        return tmq_get_vgroup_id(self._res)

    def offset(self):
        return tmq_get_vgroup_offset(self._res)
    
    def _fetch_message_block(self):
        cdef TAOS_ROW pblock
        num_of_rows = taos_fetch_block(self._res, &pblock)
        if num_of_rows == 0:
            return None

        field_count = taos_field_count(self._res)
        _fields = taos_fetch_fields(self._res)
        fields = [TaosField(f.name.decode("utf-8"), f.type, f.bytes) for f in _fields[:field_count]]
        precision = taos_result_precision(self._res)

        _table = tmq_get_table_name(self._res)
        table = "" if _table is NULL else _table.decode("utf-8")

        block = [None] * field_count
        dt_epoch = _priv_datetime_epoch if _priv_datetime_epoch else _datetime_epoch
        cdef int i
        for i in range(field_count):
            data = pblock[i]
            field = _fields[i]

            if field.type in UNSIZED_TYPE:
                offsets = taos_get_column_data_offset(self._res, i)
                block[i] = _parse_string(<size_t>data, num_of_rows, offsets)
            elif field.type in SIZED_TYPE:
                is_null = taos_get_column_data_is_null(self._res, i, num_of_rows)
                block[i] = CONVERT_FUNC[field.type](<size_t>data, num_of_rows, is_null)
            elif field.type in (TSDB_DATA_TYPE_TIMESTAMP, ):
                is_null = taos_get_column_data_is_null(self._res, i, num_of_rows)
                block[i] = _parse_timestamp(<size_t>data, num_of_rows, is_null, precision, dt_epoch)
            else:
                pass

        return MessageBlock(block, fields, num_of_rows, field_count, table)

    def value(self):
        res_type = tmq_get_res_type(self._res)
        if res_type in (tmq_res_t.TMQ_RES_TABLE_META, tmq_res_t.TMQ_RES_INVALID):
            return None

        message_blocks = []
        while True:
            mb = self._fetch_message_block()
            if not mb:
                break
            
            message_blocks.append(mb)

        return message_blocks

    def __dealloc__(self):
        if self._res is not NULL:
            taos_free_result(self._res)

        self._res = NULL
        self._err_no = 0
        self._err_str = NULL
    
cdef class TaosConsumer:
    cdef dict _configs
    cdef tmq_conf_t *_tmq_conf
    cdef tmq_t *_tmq
    cdef bool _subscribed
    default_config = {
        'group.id',
        'client.id',
        'msg.with.table.name',
        'enable.auto.commit',
        'auto.commit.interval.ms',
        'auto.offset.reset',
        'experimental.snapshot.enable',
        'enable.heartbeat.background',
        'experimental.snapshot.batch.size',
        'td.connect.ip',
        'td.connect.user',
        'td.connect.pass',
        'td.connect.port',
        'td.connect.db',
    }

    def __cinit__(self, configs: dict[str, str]):
        self._init_config(configs)
        self._init_consumer()
        self._subscribed = False

    def _init_config(self, configs: dict[str, str]):
        if 'group.id' not in configs:
            raise TmqError('missing group.id in consumer config setting')

        self._configs = configs
        self._tmq_conf = tmq_conf_new()
        if self._tmq_conf is NULL:
            raise TmqError("new tmq conf failed")

        for k, v in self._configs.items():
            _k = k.encode("utf-8")
            _v = v.encode("utf-8")
            tmq_conf_res = tmq_conf_set(self._tmq_conf, _k, _v)
            if tmq_conf_res != tmq_conf_res_t.TMQ_CONF_OK:
                tmq_conf_destroy(self._tmq_conf)
                self._tmq_conf = NULL
                raise TmqError("set tmq conf failed!")

    def _init_consumer(self):
        if self._tmq_conf is NULL:
            raise TmqError('tmq_conf is NULL')
        
        self._tmq = tmq_consumer_new(self._tmq_conf, NULL, 0)
        if self._tmq is NULL:
            raise TmqError("new tmq consumer failed")
    
    def subscribe(self, topics: list[str]):
        tmq_list = tmq_list_new()
        if tmq_list is NULL:
            raise TmqError("new tmq list failed!")
        
        for tp in topics:
            _tp = tp.encode("utf-8")
            tmq_errno = tmq_list_append(tmq_list, _tp)
            if tmq_errno != 0:
                tmq_list_destroy(tmq_list)
                raise TmqError(tmq_err2str(tmq_errno), tmq_errno)

        tmq_errno = tmq_subscribe(self._tmq, tmq_list)
        if tmq_errno != 0:
            tmq_list_destroy(tmq_list)
            raise TmqError(tmq_err2str(tmq_errno), tmq_errno)
        
        self._subscribed = True

    def unsubscribe(self):
        tmq_errno = tmq_unsubscribe(self._tmq)
        if tmq_errno != 0:
            raise TmqError(tmq_err2str(tmq_errno), tmq_errno)
        
        self._subscribed = False

    def close(self):
        if self._tmq_conf is not NULL:
            tmq_conf_destroy(self._tmq_conf)
            self._tmq_conf = NULL

        if self._tmq is not NULL:
            tmq_unsubscribe(self._tmq)
            tmq_consumer_close(self._tmq)
            self._tmq = NULL

    def poll(self, float timeout=1.0):
        if not self._subscribed:
            raise TmqError("unsubscribe topic")

        timeout_ms = int(timeout * 1000)
        res = tmq_consumer_poll(self._tmq, timeout_ms)
        if res is NULL:
            return None
        
        return Message(<size_t>res)

    def commit(self, message: Message=None, offsets: List[TopicPartition]=None):
        if message:
            self.message_commit(message)
            return 

        if offsets:
            self.offsets_commit(offsets)
            return

        tmq_commit_sync(self._tmq, NULL)

    async def commit_a(self, message: Message=None, offsets: List[TopicPartition]=None):
        if message:
            await self.message_commit_a(message)
            return

        if offsets:
            self.offsets_commit_a(offsets)

        loop = asyncio.get_event_loop()
        fut = loop.create_future()
        tmq_commit_async(self._tmq, NULL, async_commit_future_wrapper, <void*>fut)
        tmq_errno = await fut
        if tmq_errno != 0:
            raise TmqError(tmq_err2str(tmq_errno), tmq_errno)

    def message_commit(self, message: Message):
        tmq_errno = tmq_commit_sync(self._tmq, message._res)
        if tmq_errno != 0:
            raise TmqError(tmq_err2str(tmq_errno), tmq_errno)

    async def message_commit_a(self, message: Message):
        loop = asyncio.get_event_loop()
        fut = loop.create_future()
        tmq_commit_async(self._tmq, message._res, async_commit_future_wrapper, <void*>fut)
        tmq_errno = await fut
        if tmq_errno != 0:
            raise TmqError(tmq_err2str(tmq_errno), tmq_errno)

    def offsets_commit(self, topic_partitions: List[TopicPartition]):
        for tp in topic_partitions:
            tmq_errno = tmq_commit_offset_sync(self._tmq, tp._topic, tp._partition, tp._offset)
            if tmq_errno != 0:
                raise TmqError(tmq_err2str(tmq_errno), tmq_errno)
    
    async def offsets_commit_a(self, topic_partitions: List[TopicPartition]):
        loop = asyncio.get_event_loop()
        futs = []
        for tp in topic_partitions:
            fut = loop.create_future()
            tmq_commit_offset_async(self._tmq, tp._topic, tp._partition, tp._offset, async_commit_future_wrapper, <void*>fut)
            futs.append(fut)
        
        tmq_errnos = await asyncio.gather(futs, return_exceptions=True)
        for tmq_errno in tmq_errnos:
            if tmq_errno != 0:
                raise TmqError(tmq_err2str(tmq_errno), tmq_errno)

    def assignment(self):
        cdef int32_t i
        cdef int32_t num_of_assignment
        cdef tmq_topic_assignment *p_assignment = NULL

        topics = self.list_topics()
        topic_partitions = []
        for topic in topics:
            _topic = topic.encode("utf-8")
            tmq_errno = tmq_get_topic_assignment(self._tmq, _topic, &p_assignment, &num_of_assignment)
            if tmq_errno != 0:
                tmq_free_assignment(p_assignment)
                raise TmqError(tmq_err2str(tmq_errno), tmq_errno)

            for i in range(num_of_assignment):
                assignment = p_assignment[i]
                tp = TopicPartition(topic, assignment.vgId, assignment.currentOffset, assignment.begin, assignment.end)
                topic_partitions.append(tp)

            tmq_free_assignment(p_assignment)

        return topic_partitions

    def seek(self, partition: TopicPartition):
        """
        Set consume position for partition to offset.
        """
        tmq_errno = tmq_offset_seek(self._tmq, partition._topic, partition._partition, partition._offset)
        if tmq_errno != 0:
            raise TmqError(tmq_err2str(tmq_errno), tmq_errno)

        tmq_offset_seek(self._tmq, partition.topic, partition.partition, partition.offset)

    def committed(self, partitions: list[TopicPartition]) -> list[TopicPartition]:
        """
        Retrieve committed offsets for the specified partitions.

        :param list(TopicPartition) partitions: List of topic+partitions to query for stored offsets.
        :returns: List of topic+partitions with offset and possibly error set.
        :rtype: list(TopicPartition)
        """
        for partition in partitions:
            if not isinstance(partition, TopicPartition):
                raise TmqError(msg='Invalid partition type')
            offset = tmq_committed(self._tmq, partition._topic, partition._partition)

            if offset < 0:
                raise TmqError(tmq_err2str(offset), offset)
            
            partition._offset = offset

        return partitions

    def position(self, partitions: list[TopicPartition]) -> list[TopicPartition]:
        """
        Retrieve current positions (offsets) for the specified partitions.

        :param list(TopicPartition) partitions: List of topic+partitions to return current offsets for.
        :returns: List of topic+partitions with offset and possibly error set.
        :rtype: list(TopicPartition)
        """
        for partition in partitions:
            if not isinstance(partition, TopicPartition):
                raise TmqError(msg='Invalid partition type')
            offset = tmq_position(self._tmq, partition._topic, partition._partition)

            if offset < 0:
                raise TmqError(tmq_err2str(offset), offset)

            partition._offset = offset

        return partitions

    def list_topics(self):
        cdef int i
        cdef tmq_list_t *topics
        tmq_errno = tmq_subscription(self._tmq, &topics)
        if tmq_errno != 0:
            raise TmqError(tmq_err2str(tmq_errno), tmq_errno)

        n = tmq_list_get_size(topics)
        ca = tmq_list_to_c_array(topics)
        tp_list = []
        for i in range(n):
            tp_list.append(ca[i])

        tmq_list_destroy(topics)

        return tp_list

    def __iter__(self):
        while self._tmq:
            message = self.poll()
            if message:
                yield message

    def __dealloc__(self):
        self.close()

# ---------------------------------------- statement --------------------------------------------------------------- ^

cdef class TaosStmt:
    cdef TAOS_STMT *_stmt

    def __cinit__(self, size_t stmt):
        self._stmt = <TAOS_STMT*>stmt

    def _check_stmt_error(self, errno: int):
        if errno != 0:
            raise StatementError(taos_stmt_errstr(self._stmt), errno)

    def set_tbname(self, name: str):
        if self._stmt is NULL:
            raise StatementError("Invalid use of set_tbname")

        _name = name.decode("utf-8")
        errno = taos_stmt_set_tbname(self._stmt, _name)
        self._check_stmt_error(errno)

    def prepare(self, sql: str):
        if self._stmt is NULL:
            raise StatementError("Invalid use of set_tbname")

        _sql = sql.decode("utf-8")
        errno = taos_stmt_prepare(self._stmt, _sql, len(_sql))
        self._check_stmt_error(errno)

    def set_tbname_tags(self, name: str, tags: list):
        """Set table name with tags, tags is array of BindParams"""
        if self._stmt is NULL:
            raise StatementError("Invalid use of set_tbname_tags")

        errno = taos_stmt_set_tbname_tags(self._stmt, name, NULL)
        self._check_stmt_error(errno)

    def bind_param(self, TaosMultiBind[:] params, add_batch=True):
        if self._stmt is NULL:
            raise StatementError("Invalid use of stmt")

        length = len(params)
        multi_binds = <TAOS_MULTI_BIND*>malloc(length * sizeof(TAOS_MULTI_BIND))
        for i in range(length):
            multi_binds[i] = params[i]._inner
        errno = taos_stmt_bind_param(self._stmt, multi_binds)
        free(multi_binds)
        self._check_stmt_error(errno)

        if add_batch:
            self.add_batch()

    def bind_param_batch(self, TaosMultiBind[:] params, add_batch=True):
        if self._stmt is NULL:
            raise StatementError("Invalid use of stmt")

        length = len(params)
        multi_binds = <TAOS_MULTI_BIND*>malloc(length * sizeof(TAOS_MULTI_BIND))
        for i in range(length):
            multi_binds[i] = params[i]._inner
        errno = taos_stmt_bind_param_batch(self._stmt, multi_binds)
        free(multi_binds)
        self._check_stmt_error(errno)

        if add_batch:
            self.add_batch()

    def add_batch(self):
        if self._stmt is NULL:
            raise StatementError("Invalid use of stmt")
        
        errno = taos_stmt_add_batch(self._stmt)
        self._check_stmt_error(errno)

    def execute(self):
        if self._stmt is NULL:
            raise StatementError("Invalid use of execute")

        errno = taos_stmt_execute(self._stmt)
        self._check_stmt_error(errno)

    def use_result(self):
        if self._stmt is NULL:
            raise StatementError("Invalid use of use_result")
        
        res = taos_stmt_use_result(self._stmt)
        if res is NULL:
            raise StatementError(taos_stmt_errstr(self._stmt))

        return TaosResult(<size_t>res)

    @property
    def affected_rows(self):
        # type: () -> int
        return taos_stmt_affected_rows(self._stmt)

    def close(self):
        """Close stmt."""
        if self._stmt is NULL:
            return

        errno = taos_stmt_close(self._stmt)
        self._check_stmt_error(errno)
        self._stmt = NULL

    def __dealloc__(self):
        self.close()

cdef class TaosMultiBind:
    cdef TAOS_MULTI_BIND _inner

    def bool(self, values):
        self._inner.buffer_type = FieldType.C_BOOL
        self._inner.buffer_length = sizeof(bool)
        self._inner.num = len(values)
        _buffer = <int8_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <int8_t>FieldType.C_BOOL_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <int8_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def tinyint(self, values):
        self._inner.buffer_type = FieldType.C_TINYINT
        self._inner.buffer_length = sizeof(int8_t)
        self._inner.num = len(values)
        _buffer = <int8_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <int8_t>FieldType.C_TINYINT_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <int8_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def smallint(self, values):
        self._inner.buffer_type = FieldType.C_SMALLINT
        self._inner.buffer_length = sizeof(int16_t)
        self._inner.num = len(values)
        _buffer = <int16_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <int16_t>FieldType.C_SMALLINT_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <int16_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def int(self, values):
        self._inner.buffer_type = FieldType.C_INT
        self._inner.buffer_length = sizeof(int32_t)
        self._inner.num = len(values)
        _buffer = <int32_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <int32_t>FieldType.C_INT_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <int32_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def bigint(self, values):
        self._inner.buffer_type = FieldType.C_BIGINT
        self._inner.buffer_length = sizeof(int64_t)
        self._inner.num = len(values)
        _buffer = <int64_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <int64_t>FieldType.C_BIGINT_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <int64_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def float(self, values):
        self._inner.buffer_type = FieldType.C_FLOAT
        self._inner.buffer_length = sizeof(float)
        self._inner.num = len(values)
        _buffer = <float*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <float>FieldType.C_FLOAT_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <float>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def double(self, values):
        self._inner.buffer_type = FieldType.C_DOUBLE
        self._inner.buffer_length = sizeof(double)
        self._inner.num = len(values)
        _buffer = <double*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <double>FieldType.C_DOUBLE_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <double>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def tinyint_unsigned(self, values):
        self._inner.buffer_type = FieldType.C_TINYINT_UNSIGNED
        self._inner.buffer_length = sizeof(uint8_t)
        self._inner.num = len(values)
        _buffer = <uint8_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <uint8_t>FieldType.C_TINYINT_UNSIGNED_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <uint8_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def smallint_unsigned(self, values):
        self._inner.buffer_type = FieldType.C_SMALLINT_UNSIGNED
        self._inner.buffer_length = sizeof(uint16_t)
        self._inner.num = len(values)
        _buffer = <uint16_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <uint16_t>FieldType.C_SMALLINT_UNSIGNED_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <uint16_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def int_unsigned(self, values):
        self._inner.buffer_type = FieldType.C_INT_UNSIGNED
        self._inner.buffer_length = sizeof(uint32_t)
        self._inner.num = len(values)
        _buffer = <uint32_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <uint32_t>FieldType.C_INT_UNSIGNED_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <uint32_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def bigint_unsigned(self, values):
        self._inner.buffer_type = FieldType.C_BIGINT_UNSIGNED
        self._inner.buffer_length = sizeof(uint64_t)
        self._inner.num = len(values)
        _buffer = <uint64_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <uint64_t>FieldType.C_BIGINT_UNSIGNED_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <uint64_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null

    def timestamp(self, values, precision):
        self._inner.buffer_type = FieldType.C_TIMESTAMP
        self._inner.buffer_length = sizeof(int64_t)
        self._inner.num = len(values)
        _buffer = <int64_t*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))

        dt_epoch = _priv_datetime_epoch if _priv_datetime_epoch else _datetime_epoch

        if len(values) > 0:
            if isinstance(values[0], dt.datetime):
                values = [int(round((v - dt_epoch).total_seconds() * 10**(3*(precision+1)))) for v in values]
            elif isinstance(values[0], str):
                for i, v in enumerate(values):
                    v = dt.datetime.fromisoformat(v)
                    values[i] = int(round((v - dt_epoch).total_seconds() * 10**(3*(precision+1))))
            elif isinstance(values[0], float):
                values = [int(round(v * 10**(3*(precision+1)))) for v in values]
            else:
                pass

        for i in range(self._inner.num):
            v = values[i]
            if v is None:
                _buffer[i] = <int64_t>FieldType.C_BIGINT_NULL
                _is_null[i] = 1
            else:
                _buffer[i] = <int64_t>v
                _is_null[i] = 0
        
        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null


    def binary(self, values):
        _bytes = [v.encode("utf-8") for v in values if v is not None]
        self._inner.buffer_type = FieldType.C_BINARY
        self._inner.buffer_length = max(len(b) for b in _bytes if b is not None)
        self._inner.num = len(values)
        _length = <int32_t*>malloc(self._inner.num * sizeof(int32_t))
        _buffer = <char*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))


        for i in range(self._inner.num):
            offset = i * self._inner.buffer_length
            v = _bytes[i]
            if v is None:
                _buffer[offset] = b"\x00"
                _is_null[i] = 1
                _length[i] = 0
            else:
                _buffer[i] = v
                _is_null[i] = 0
                _length[i] = len(v)

        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null
        self._inner.length = _length

    def nchar(self, values):
        _bytes = [v.encode("utf-8") for v in values if v is not None]
        self._inner.buffer_type = FieldType.C_NCHAR
        self._inner.buffer_length = max(len(b) for b in _bytes if b is not None)
        self._inner.num = len(values)
        _length = <int32_t*>malloc(self._inner.num * sizeof(int32_t))
        _buffer = <char*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))


        for i in range(self._inner.num):
            offset = i * self._inner.buffer_length
            v = _bytes[i]
            if v is None:
                _buffer[offset] = b"\x00"
                _is_null[i] = 1
                _length[i] = 0
            else:
                _buffer[i] = v
                _is_null[i] = 0
                _length[i] = len(v)

        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null
        self._inner.length = _length

    def json(self, values):
        _bytes = [v.encode("utf-8") for v in values if v is not None]
        self._inner.buffer_type = FieldType.C_JSON
        self._inner.buffer_length = max(len(b) for b in _bytes if b is not None)
        self._inner.num = len(values)
        _length = <int32_t*>malloc(self._inner.num * sizeof(int32_t))
        _buffer = <char*>malloc(self._inner.num * self._inner.buffer_length)
        _is_null = <char*>malloc(self._inner.num * sizeof(char))


        for i in range(self._inner.num):
            offset = i * self._inner.buffer_length
            v = _bytes[i]
            if v is None:
                _buffer[offset] = b"\x00"
                _is_null[i] = 1
                _length[i] = 0
            else:
                _buffer[i] = v
                _is_null[i] = 0
                _length[i] = len(v)

        self._inner.buffer = <void*>_buffer
        self._inner.is_null = <char*>_is_null
        self._inner.length = _length

    def __dealloc__(self):
        if self._inner.buffer is not NULL:
            free(self._inner.buffer)
            self._inner.buffer = NULL

        if self._inner.is_null is not NULL:
            free(self._inner.is_null)
            self._inner.is_null = NULL

        if self._inner.length is not NULL:
            free(self._inner.length)
            self._inner.length = NULL
