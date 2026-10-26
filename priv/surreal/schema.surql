-- Application tables. Record identity and domain validation live in the stores.
-- Schema only: no users, credentials, jobs, or other fixture data.
DEFINE TABLE IF NOT EXISTS app_user TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS auth_identity TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS auth_session TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS auth_token TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS chat TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS credential_secret TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS job TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS job_feedback TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS job_metric TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS mail_outbox TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS provisioned_account TYPE ANY SCHEMALESS PERMISSIONS NONE;
DEFINE TABLE IF NOT EXISTS provisioned_mailbox TYPE ANY SCHEMALESS PERMISSIONS NONE;

DEFINE INDEX IF NOT EXISTS auth_identity_user_id ON auth_identity FIELDS user_id UNIQUE;
DEFINE INDEX IF NOT EXISTS auth_session_token_hash ON auth_session FIELDS token_hash UNIQUE;
DEFINE INDEX IF NOT EXISTS auth_session_user_id ON auth_session FIELDS user_id;
DEFINE INDEX IF NOT EXISTS auth_token_user_purpose ON auth_token FIELDS user_id, purpose;
DEFINE INDEX IF NOT EXISTS chat_user_id ON chat FIELDS user_id;
DEFINE INDEX IF NOT EXISTS job_feedback_user_created ON job_feedback FIELDS user_id, created_at;
DEFINE INDEX IF NOT EXISTS job_owner_created ON job FIELDS user_id, created_at;
DEFINE INDEX IF NOT EXISTS job_metric_owner_attempt ON job_metric FIELDS user_id, job_id, attempt, recorded_at;
DEFINE INDEX IF NOT EXISTS mail_outbox_status_next_attempt ON mail_outbox FIELDS status, next_attempt_at;
DEFINE INDEX IF NOT EXISTS provisioned_mailbox_provider_email ON provisioned_mailbox FIELDS provider, email UNIQUE;
