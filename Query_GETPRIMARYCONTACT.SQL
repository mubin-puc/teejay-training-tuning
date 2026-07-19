SELECT 
    ps.execution_count,
    ps.last_execution_time,
    ps.total_worker_time / ps.execution_count / 1000.0 AS avg_cpu_time_ms,
    ps.last_worker_time / 1000.0 AS last_cpu_time_ms,
    ps.total_elapsed_time / ps.execution_count / 1000.0 AS avg_elapsed_time_ms,
    ps.last_elapsed_time / 1000.0 AS last_elapsed_time_ms,
    ps.cached_time
FROM sys.dm_exec_procedure_stats ps
JOIN sys.procedures p ON ps.object_id = p.object_id
WHERE p.name = 'GetPrimaryContactsForFabric';
