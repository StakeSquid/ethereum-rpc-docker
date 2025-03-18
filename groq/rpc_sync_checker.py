import os
import sys
from groq import Groq

def check_sync_progress(logs):
    client = Groq(api_key=os.environ.get("GROQ_API_KEY"))
    
    response = client.chat.completions.create(
        messages=[
            {"role": "system", "content": "You are an assistant trained to analyze blockchain RPC logs."},
            {"role": "user", "content": f"Based on the following logs, is the RPC node progressing in its sync? Answer only '0' for yes and '1' for no.\n\n{logs}"}
        ],
        model="llama-3.3-70b-versatile",
    )
    
    return response.choices[0].message.content.strip()

if __name__ == "__main__":
    logs = sys.stdin.read()  # Read input from STDIN
    result = check_sync_progress(logs)
    print(result)
