-- BackupType: ONLINE
-- AS support: NO
UPDATE COMMAND OPTIONS USING S ON Z ON /db2exports/db2scripts/logs/db2_generate_redirected_restore_script/vr8db201t/ambikas/2021-03-16-14.03.52_AMBIKAS_to_AMBIKAS.out V ON;
SET CLIENT ATTACH_MEMBER  0;
SET CLIENT CONNECT_MEMBER 0;
-- /* Start clean up of LOGTARGET */
! mkdir -p /db2exports/db2scripts/logs/db2_generate_redirected_restore_script/vr8db201t/ambikas/2021-03-16-14.03.52_AMBIKAS_to_AMBIKAS_LOGS > /dev/null 2>&1 ;
! rm -fR /db2exports/db2scripts/logs/db2_generate_redirected_restore_script/vr8db201t/ambikas/2021-03-16-14.03.52_AMBIKAS_to_AMBIKAS_LOGS/* > /dev/null 2>&1 ;
-- /* End clean up of LOGTARGET */
RESTORE DATABASE AMBIKAS
-- USER  <username>
-- USING '<password>'
FROM '/db2scripts/backup/backup_vr8db201a/ambikas'
TAKEN AT 20210316081356
-- ON '/var/opt/db2/data'  -- Not usable, because database does not support Automatic Storage (SQL2321N)
DBPATH ON '/db2data'
INTO AMBIKAS
LOGTARGET /db2exports/db2scripts/logs/db2_generate_redirected_restore_script/vr8db201t/ambikas/2021-03-16-14.03.52_AMBIKAS_to_AMBIKAS_LOGS
-- NEWLOGPATH /db2activelogs/AMBIKAS/AMBIKAS
-- WITH <num-buff> BUFFERS
-- BUFFER <buffer-size>
-- REPLACE HISTORY FILE
REPLACE EXISTING
REDIRECT
-- PARALLELISM <n>
-- COMPRLIB '<lib-name>'
-- COMPROPTS '<options-string>'
-- WITHOUT ROLLING FORWARD
-- WITHOUT PROMPTING
;
-- SET STOGROUP PATHS FOR IBMSTOGROUP
-- ON '/db2data'
-- ;
RESTORE DATABASE AMBIKAS CONTINUE;

--
-- Suggestions for rollforward:
--
--  ROLLFORWARD DB AMBIKAS TO [END OF BACKUP|YYYY-MM-DD-HH.MM.SS USING LOCAL TIME|END OF LOGS]
--    [AND COMPLETE|STOP]
--    OVERFLOW LOG PATH ('/db2exports/db2scripts/logs/db2_generate_redirected_restore_script/vr8db201t/ambikas/2021-03-16-14.03.52_AMBIKAS_to_AMBIKAS_LOGS') NORETRIEVE ;
--
-- Not required when restoring to the same version of Db2, being v11.5.5.0 - build s2011011400:
--
--  UPGRADE DB AMBIKAS ;
--
