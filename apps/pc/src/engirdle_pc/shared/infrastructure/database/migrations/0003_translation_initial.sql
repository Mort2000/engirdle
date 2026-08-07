CREATE TABLE IF NOT EXISTS translations (
    job_id TEXT NOT NULL,
    sentence_id TEXT NOT NULL,
    generated_text TEXT NOT NULL,
    edited_text TEXT,
    adapter_name TEXT NOT NULL,
    PRIMARY KEY (job_id, sentence_id),
    FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
);
