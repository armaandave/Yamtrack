import os

bind = "localhost:8001"
preload_app = True
worker_class = "gthread"
workers = int(os.environ.get("GUNICORN_WORKERS", os.environ.get("WEB_CONCURRENCY", "2")))
threads = int(os.environ.get("GUNICORN_THREADS", "4"))
if workers < 1 or threads < 1:
    raise ValueError("Gunicorn workers and threads must be positive integers")
timeout = 200
max_requests = 500
max_requests_jitter = 10

accesslog = "-"
errorlog = "-"
