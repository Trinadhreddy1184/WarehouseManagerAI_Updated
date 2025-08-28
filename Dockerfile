FROM python:3.11-slim
WORKDIR /opt/WarehouseManagerAI
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONPATH=/opt/WarehouseManagerAI
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /opt/WarehouseManagerAI/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt || \
    pip install --no-cache-dir SQLAlchemy>=2.0 psycopg2-binary>=2.9 pandas omegaconf streamlit
COPY . /opt/WarehouseManagerAI
EXPOSE 8501
CMD ["bash","-lc","streamlit run ui/streamlit_ui.py --server.port=8501 --server.address=0.0.0.0"]
