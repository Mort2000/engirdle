CREATE TABLE IF NOT EXISTS sentence_audio (
    job_id TEXT NOT NULL,
    sentence_id TEXT NOT NULL,
    pcm_path TEXT NOT NULL,
    sample_rate_hz INTEGER NOT NULL,
    sample_count INTEGER NOT NULL,
    adapter_name TEXT NOT NULL,
    PRIMARY KEY (job_id, sentence_id),
    FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
);
